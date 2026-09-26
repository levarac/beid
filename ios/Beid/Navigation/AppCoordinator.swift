// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import BeidSharedKit
import Combine
import Foundation

/// Root state machine for onboarding + the collection home. Order of the
/// wallet step is decided once at init from `OnboardingMode.current`; see
/// README "Onboarding flag".
@MainActor
final class AppCoordinator: ObservableObject {
  @Published var screen: AppScreen = .welcome
  @Published var walletAddress: String?
  /// The address from this process's live connector session, if any — the
  /// only wallet-address value `EventBindingSheetView.performBinding` is
  /// allowed to read for its "already connected" fast path (beid#315
  /// structural containment; see `LiveWalletAddress`'s doc comment in
  /// `WalletConnector.swift`). `walletAddress` above stays a plain,
  /// freely-settable `String?` for display only (previews/tests already
  /// assign it directly) and is never read on that path.
  @Published private(set) var liveWalletAddress: LiveWalletAddress?
  @Published var scanPresented = false
  @Published var selectedProof: Proof?
  @Published var accountSheetPresented = false
  @Published var walletConnectSheetPresented = false
  @Published var eventCodeEntrySheetPresented = false
  @Published var dailySummaryPresented = false

  private(set) var walletConnector: (any WalletConnector)?

  let onboardingMode = OnboardingMode.current
  let proofStore: ProofStore
  let registryClient: ExportedKotlinPackages.org.levarac.parallax.registry.RegistryClient?
  let sensingCoordinator: SensingCoordinator
  let supportDiagnostics: SupportDiagnostics
  let bluetoothMonitor: BluetoothMonitor
  /// beid#464's device-clock preflight, checked each time the scan flow opens.
  let clockPreflight: ClockPreflightController
  private let userDefaults: UserDefaults
  private let permissionEvaluation: (() async -> BluetoothAuthorizationState)?

  private static let hasCompletedOnboardingKey = "beid.hasCompletedOnboarding"

  /// `registryClient` defaults to the production, Info.plist-driven
  /// resolution (`RegistryDependencies.createClient()`), evaluated fresh at
  /// each call site with no override — mirroring `walletConnector`/
  /// `proofStore`'s existing injectability so tests can point the coordinator
  /// at a fake/stub registry without touching `Bundle.main`. An explicit
  /// `nil` here is a meaningful test input (an app build with no registry
  /// configured), not "use the default" — so this is a plain default
  /// expression, not a `?? RegistryDependencies.createClient()` fallback.
  init(
    walletConnector: (any WalletConnector)? = nil,
    proofStore: ProofStore? = nil,
    registryClient: ExportedKotlinPackages.org.levarac.parallax.registry.RegistryClient? =
      RegistryDependencies.createClient(),
    userDefaults: UserDefaults = .standard,
    permissionEvaluation: (() async -> BluetoothAuthorizationState)? = nil
  ) {
    let bluetoothMonitor = BluetoothMonitor()
    self.registryClient = registryClient
    self.sensingCoordinator = SensingCoordinator(registryClient: registryClient)
    self.supportDiagnostics = SupportDiagnostics(
      phases: sensingCoordinator.$phase.eraseToAnyPublisher(),
      refusalReasons: sensingCoordinator.$joinRefusalReasonKey.eraseToAnyPublisher(),
      ownerKeyFailures: sensingCoordinator.$ownerKeyOperationFailure.eraseToAnyPublisher()
    )
    self.clockPreflight = ClockPreflightController(
      source: OperatorDateHeaderSource(origin: Self.clockPreflightOrigin())
    )
    self.walletConnector = walletConnector
    self.proofStore = proofStore ?? ProofStore()
    self.userDefaults = userDefaults
    self.bluetoothMonitor = bluetoothMonitor
    #if DEBUG
    if permissionEvaluation == nil,
      ProcessInfo.processInfo.arguments.contains("-beid-ui-test")
    {
      // UI tests run without a real CoreBluetooth daemon. Keep their existing
      // onboarding contract deterministic while production and normal Debug
      // launches continue to wait for the real authorization callback.
      self.permissionEvaluation = { .granted }
    } else {
      self.permissionEvaluation = permissionEvaluation
    }
    #else
    self.permissionEvaluation = permissionEvaluation
    #endif
    if proofStore == nil, shouldResetProofStoreForUITesting {
      self.proofStore.resetForUITesting()
    }
    sensingCoordinator.onProofCollected = { [weak self] proof in
      self?.proofStore.add(proof)
    }
    if hasCompletedOnboardingPersisted {
      restoreAfterOnboarding()
    }
  }

  deinit {
    registryClient?.close()
  }

  // MARK: - Onboarding

  /// Gates the restore *read* behind `-beid-ui-test` (mirroring
  /// `SensingCoordinator.demoStepDelayNanos`'s existing use of the same
  /// launch argument) so a UI test launch always starts at `.welcome`
  /// regardless of what a prior launch left in `UserDefaults.standard` — see
  /// #194's cross-UI-test pollution risk (`BeidIPadLayoutTests` reuses one
  /// installed app's container across `testPrimaryFlowInPortrait` and
  /// `testPrimaryFlowInLandscape`). Release builds never receive
  /// `-beid-ui-test`, so the `#if DEBUG` split does not change Release
  /// behavior.
  private var hasCompletedOnboardingPersisted: Bool {
    #if DEBUG
    guard !ProcessInfo.processInfo.arguments.contains("-beid-ui-test") else { return false }
    #endif
    return userDefaults.bool(forKey: Self.hasCompletedOnboardingKey)
  }

  /// Same launch-argument gate as `hasCompletedOnboardingPersisted` above,
  /// applied to the default `ProofStore` instead of the onboarding flag —
  /// beid#244. `#if DEBUG` means Release builds (which never receive
  /// `-beid-ui-test`) cannot reach this regardless of the argument check.
  private var shouldResetProofStoreForUITesting: Bool {
    #if DEBUG
    return ProcessInfo.processInfo.arguments.contains("-beid-ui-test")
    #else
    return false
    #endif
  }

  /// Restores a previously set-up device past `.welcome` on cold launch
  /// (#194) by re-driving the same `beginOnboarding()` → (guestFirst)
  /// `requestBluetoothPermission()` → `evaluateBluetoothState()` path a
  /// first-run user takes, so a currently-powered-off radio still correctly
  /// routes to `.bluetoothOff` instead of `.home` (the failure mode this
  /// exists to prevent — a restored user must never be dropped onto `.home`
  /// with a dead radio).
  ///
  /// `.walletFirst` restore is intentionally left exactly as
  /// `beginOnboarding()`'s existing `.walletConnect` routing — i.e. it does
  /// not skip wallet-connect. Deciding how a previously-connected wallet
  /// should restore intersects #202 Q6 (wallet-unconnected guest handling),
  /// which is explicitly out of scope here; `.walletFirst` isn't
  /// `OnboardingMode.current` in production, so this is a documented,
  /// accepted limitation, not a regression.
  private func restoreAfterOnboarding() {
    beginOnboarding()
    if screen == .bluetoothPermission {
      requestBluetoothPermission()
    }
  }

  func beginOnboarding() {
    switch onboardingMode {
    case .walletFirst:
      screen = .walletConnect
    case .guestFirst:
      screen = .bluetoothPermission
    }
  }

  /// `address` is supplied by `WalletConnectPairingView` (MetaMask) once a
  /// session settles.
  func completeWalletConnect(address: LiveWalletAddress, connector: (any WalletConnector)? = nil) {
    recordWalletConnection(address: address, connector: connector)
    screen = .bluetoothPermission
  }

  /// Takes `LiveWalletAddress`, not a plain `String` — every production
  /// caller already has one, straight from a connector's own successful
  /// `connect()`/`connectAndSign()` (see `WalletConnectPairingView.onConnected`
  /// and `EventBindingSheetView`'s restored-hint fast path). This is part of
  /// beid#315's structural containment: a bare `String` (e.g. read from a
  /// `CachedWalletHint`) cannot be passed here without first being wrapped in
  /// a visible `LiveWalletAddress(...)` construction.
  func recordWalletConnection(address: LiveWalletAddress, connector: (any WalletConnector)? = nil) {
    if let connector {
      walletConnector = connector
    }
    liveWalletAddress = address
    walletAddress = address.address
  }

  /// Wallet-optional fallback from `WalletConnectView`'s secondary action:
  /// join an event by manually entered code instead of connecting a wallet.
  func skipWalletForEventCode() {
    screen = .eventCodeEntry
  }

  /// The way back out of `EventCodeEntryView` for a user who doesn't
  /// actually have a code — this is a root-switch screen (not a modal
  /// push), so there is no system back affordance without this.
  ///
  /// Also abandons any join attempt still resolving its lookup: without
  /// this, a user who taps this while a code-entry lookup is in flight and
  /// then reaches `.walletConnect` could later be silently yanked into
  /// `.bluetoothPermission` when that stale lookup finally completes and
  /// `joinEvent` succeeds — a screen change the user never asked for, for
  /// an event they explicitly walked away from (beid#258 P1-1 round-2 fix).
  func returnToWalletConnect() {
    cancelPendingJoinAttempt()
    screen = .walletConnect
  }

  /// Validates and joins the manually entered event code
  /// (`EventCodeEntryView`), calling into the Barnard SDK's join
  /// API via `SensingCoordinator`. On success, advances onboarding exactly
  /// where `completeWalletConnect()` does, without ever setting
  /// `walletAddress`.
  @discardableResult
  func joinEvent(
    code rawCode: String,
    canonicalEventIdHex: String? = nil,
    lookupErrorCode: String? = nil
  ) -> EventCodeJoinError? {
    if let error = attemptJoinEvent(
      code: rawCode,
      canonicalEventIdHex: canonicalEventIdHex,
      lookupErrorCode: lookupErrorCode
    ) {
      return error
    }
    screen = .bluetoothPermission
    return nil
  }

  /// Validates and joins the manually entered event code from
  /// `EventCodeEntryView` presented as a sheet over the Account sheet (see
  /// `AccountSheetView`'s `eventCodeEntrySheetPresented` binding). Unlike
  /// `joinEvent(code:)`, success here just dismisses the sheet — it never
  /// touches `screen`, since the user is already past onboarding.
  @discardableResult
  func joinEventFromAccountSheet(
    code rawCode: String,
    canonicalEventIdHex: String? = nil,
    lookupErrorCode: String? = nil
  ) -> EventCodeJoinError? {
    if let error = attemptJoinEvent(
      code: rawCode,
      canonicalEventIdHex: canonicalEventIdHex,
      lookupErrorCode: lookupErrorCode
    ) {
      return error
    }
    eventCodeEntrySheetPresented = false
    return nil
  }

  /// Best-effort code -> canonical registry Event ID lookup, via the
  /// deployment-configured operator lookup endpoint (beid#258 P1-1 interim
  /// mechanism — see dispatch#21 for the durable, cryptographically-bound
  /// replacement). This is a routing hint only, never a trust boundary: a
  /// wrong or malicious answer can only point the caller at a different
  /// *registered* event, because whatever ID comes back still has to pass
  /// `RegistryClient.resolveEventDefinition`'s full on-chain and
  /// authority-signature verification before anything derived from it is
  /// trusted. Never throws: a missing client, unconfigured lookup, or any
  /// network failure all resolve to `nil`, which is `attemptJoinEvent`'s
  /// existing fail-closed default — callers do not need their own fallback.
  ///
  /// Takes `code` as a plain value, not read from a caller's live `@State` —
  /// this method's own body is the only place that reads it, exactly once,
  /// before the `await` below. A caller that instead re-reads a mutable
  /// binding after awaiting a sibling composed method (below) would pair a
  /// lookup result for one code with a join for whatever the binding holds
  /// by the time the lookup returns, which need not be the same code.
  /// Test-only override point: when set, replaces this method's real
  /// `registryClient` call entirely. Production code never sets this — the
  /// default `nil` means "use the real lookup" and nothing else in this
  /// file reads it. It exists solely so a test can control exactly when a
  /// lookup resumes (via its own `CheckedContinuation`), to deterministically
  /// exercise `joinAttemptGeneration` supersession under a genuine
  /// concurrent race — `createSepoliaRegistryClient` refuses loopback HTTP
  /// for every URL template, so there is no other way to get a real,
  /// test-controllable suspension point here without either a flaky
  /// wall-clock-dependent test or this seam (beid#258 P1-1 round-3).
  /// Returns the whole lookup, not just the id: a test that cannot express
  /// "the registry answered with this error code" cannot reach the reasons
  /// beid#472 exists to show, and the shape here should be the shape
  /// production produces.
  var resolveCanonicalEventIdHexOverride: ((String) async -> CanonicalEventIdLookup)?

  /// What a code-to-id lookup produced: the id when it answered, and the
  /// registry's own `errorCode` when it did not.
  ///
  /// The error code used to be dropped on the floor here. That is what made
  /// "you are offline" and "no such event" indistinguishable to the caller,
  /// and so to the participant — the one distinction `shared/`'s
  /// `eventJoinFailureReasonForRegistryErrorCode` exists to draw, and which
  /// Android has drawn since beid#463 (beid#472).
  struct CanonicalEventIdLookup {
    let eventIdHex: String?
    /// `nil` when the lookup answered, or when there was nothing to ask
    /// (no registry configured, code not normalizable) — those are not
    /// registry error codes and must not be classified as if they were.
    let errorCode: String?

    static let noAnswer = CanonicalEventIdLookup(eventIdHex: nil, errorCode: nil)
  }

  func resolveCanonicalEventIdHex(forCode rawCode: String) async -> String? {
    await lookUpCanonicalEventId(forCode: rawCode).eventIdHex
  }

  func lookUpCanonicalEventId(forCode rawCode: String) async -> CanonicalEventIdLookup {
    if let resolveCanonicalEventIdHexOverride {
      return await resolveCanonicalEventIdHexOverride(rawCode)
    }
    guard let registryClient else { return .noAnswer }
    guard let normalized = BeidSharedKit.event.normalizedEventCodeOrNull(rawEventCode: rawCode) else {
      return .noAnswer
    }
    return await withCheckedContinuation { continuation in
      registryClient.resolveEventId(code: normalized) { resolution in
        continuation.resume(
          returning: CanonicalEventIdLookup(
            eventIdHex: resolution.isSuccess ? resolution.eventIdHex : nil,
            errorCode: resolution.isSuccess ? nil : resolution.errorCode
          )
        )
      }
    }
  }

  /// Monotonic counter guarding every composed "resolve, then join" attempt
  /// below against a newer attempt superseding it mid-flight — the user
  /// double-taps Join, edits the code field while a lookup is in flight,
  /// taps a different past-events row before an earlier lookup returns, or
  /// leaves the join surface entirely (`cancelPendingJoinAttempt`). Only one
  /// shared counter across all composed methods: they all fight over
  /// the same single-slot join state (`SensingCoordinator.joinedEventCode`),
  /// so the latest attempt or cancellation from any of them should win, not
  /// just the latest within its own surface.
  private var joinAttemptGeneration = 0

  /// Result of a composed "resolve, then join" attempt below.
  /// `.superseded` means exactly that and nothing else: the attempt neither
  /// succeeded nor failed, because a newer attempt (or an explicit
  /// cancellation) started first. Callers must not treat `.superseded` as
  /// `.completed(nil)` — both are "no error to show", but only the second
  /// means *this* attempt actually ran and its caller's UI state should
  /// reflect it. Collapsing the two let a stale attempt's late completion
  /// silently clear a newer attempt's error message (beid#258 P1-1 round-2
  /// fix) — the whole reason this is a dedicated type and not `T?`.
  enum JoinAttemptOutcome: Equatable {
    case superseded
    case completed(EventCodeJoinError?)
  }

  /// Bumps `joinAttemptGeneration` with no new attempt starting — the
  /// explicit "the user left this join surface" signal. Any composed
  /// attempt already in flight will see its generation stale when its
  /// lookup resumes and report `.superseded` instead of joining or touching
  /// UI state on the caller's behalf.
  private func cancelPendingJoinAttempt() {
    joinAttemptGeneration += 1
  }

  /// Composes `resolveCanonicalEventIdHex` with `joinEvent(code:canonicalEventIdHex:)`
  /// for one code, snapshotted once as `code` itself — see that function's
  /// own doc comment for why this matters. Returns `.superseded` with no
  /// join attempted at all if a newer call to any of the three composed
  /// methods (or an explicit cancellation) started before this one's lookup
  /// finished.
  func joinEventResolvingCanonicalId(code: String) async -> JoinAttemptOutcome {
    joinAttemptGeneration += 1
    let generation = joinAttemptGeneration
    let lookup = await lookUpCanonicalEventId(forCode: code)
    guard generation == joinAttemptGeneration else { return .superseded }
    return .completed(
      joinEvent(
        code: code,
        canonicalEventIdHex: lookup.eventIdHex,
        lookupErrorCode: lookup.errorCode
      )
    )
  }

  /// Same composition as `joinEventResolvingCanonicalId`, for the
  /// account-sheet join surface.
  func joinEventFromAccountSheetResolvingCanonicalId(code: String) async -> JoinAttemptOutcome {
    joinAttemptGeneration += 1
    let generation = joinAttemptGeneration
    let lookup = await lookUpCanonicalEventId(forCode: code)
    guard generation == joinAttemptGeneration else { return .superseded }
    return .completed(
      joinEventFromAccountSheet(
        code: code,
        canonicalEventIdHex: lookup.eventIdHex,
        lookupErrorCode: lookup.errorCode
      )
    )
  }

  /// Manual rescue from the nearby-event scan surface. It preserves the same
  /// operator-lookup evidence path as every other typed-code join, then starts
  /// sensing inside the already-presented scan flow only after selection
  /// succeeds. The later engine call still goes through the capability-only
  /// `EventJoinControlling.joinAndStart` boundary.
  func joinEventFromScanFlowResolvingCanonicalId(code: String) async -> JoinAttemptOutcome {
    joinAttemptGeneration += 1
    let generation = joinAttemptGeneration
    let lookup = await lookUpCanonicalEventId(forCode: code)
    guard generation == joinAttemptGeneration else { return .superseded }
    let error = attemptJoinEvent(
      code: code,
      canonicalEventIdHex: lookup.eventIdHex,
      lookupErrorCode: lookup.errorCode
    )
    if error == nil {
      sensingCoordinator.startSensing()
    }
    return .completed(error)
  }

  /// Call when the account-sheet join surface is dismissed (Cancel or
  /// swipe) while a lookup may still be in flight — see
  /// `cancelPendingJoinAttempt`'s doc comment and `returnToWalletConnect`'s
  /// onboarding-side equivalent.
  func cancelPendingAccountSheetJoinAttempt() {
    cancelPendingJoinAttempt()
  }

  /// Same composition as `joinEventResolvingCanonicalId`, for rejoining a
  /// past event. `rejoinPastEvent` has no return value to discard on a
  /// superseded attempt; the guard here still prevents it from firing at all.
  func rejoinPastEventResolvingCanonicalId(code: String) async {
    joinAttemptGeneration += 1
    let generation = joinAttemptGeneration
    let canonicalEventIdHex = await resolveCanonicalEventIdHex(forCode: code)
    guard generation == joinAttemptGeneration else { return }
    rejoinPastEvent(code: code, canonicalEventIdHex: canonicalEventIdHex)
  }

  /// Shared join attempt behind both `joinEvent(code:)` and
  /// `joinEventFromAccountSheet(code:)` — validates and calls into
  /// `SensingCoordinator`, without deciding what happens on success.
  ///
  /// Canonicalization (surrounding whitespace trimmed, then case folded) is
  /// `BeidSharedKit.event.normalizedEventCodeOrNull(rawEventCode:)`
  /// (beid#226, DECISIONS 2026-08-20) — a `shared/` decision so iOS and
  /// Android derive the same RPID from the same typed text, not a native
  /// `.trimmingCharacters` check.
  private func attemptJoinEvent(
    code rawCode: String,
    canonicalEventIdHex: String? = nil,
    lookupErrorCode: String? = nil
  ) -> EventCodeJoinError? {
    guard let normalized = BeidSharedKit.event.normalizedEventCodeOrNull(rawEventCode: rawCode) else {
      return .emptyCode
    }
    guard sensingCoordinator.joinEvent(
      normalized,
      canonicalEventIdHex: canonicalEventIdHex,
      lookupErrorCode: lookupErrorCode
    ) else {
      return .joinFailed
    }
    return nil
  }

  /// Clears a manually joined event code, mirroring `joinEvent(code:)`.
  func leaveEvent() {
    sensingCoordinator.leaveEvent()
  }

  /// Rejoins a previously joined event by an already-known `Proof.eventCode`
  /// (beid#230's past-events list), instead of retyping it through
  /// `EventCodeEntryView`. A no-op while an event is already joined —
  /// matches the single-slot invariant `EventMembershipUITests` already
  /// covers for "Join Event"; the caller is expected to disable the row the
  /// same way, but this does not rely on that as its only guard.
  ///
  /// Routes through `attemptJoinEvent(code:)` (beid#226, DECISIONS
  /// 2026-08-20) so there is exactly one iOS call site into
  /// `normalizedEventCodeOrNull`, not two. A `Proof.eventCode` stored before
  /// this change may carry surrounding whitespace or mixed case that a fresh
  /// join of the same text would no longer produce; sharing
  /// `attemptJoinEvent`'s normalization here means a legacy-cased stored
  /// code rejoins to the same RPID a fresh join of the same text derives
  /// today, instead of reproducing whatever it happened to canonicalize to
  /// under the old, platform-diverging rule. The return value is discarded:
  /// a stored `Proof.eventCode` cannot normalize to empty (it was itself
  /// produced by a successful join), and a `.joinFailed` here has no
  /// separate UI to report to, matching this function's pre-existing
  /// `Bool`-discarding call into `SensingCoordinator`.
  func rejoinPastEvent(code: String, canonicalEventIdHex: String? = nil) {
    guard sensingCoordinator.joinedEventCode == nil else { return }
    _ = attemptJoinEvent(code: code, canonicalEventIdHex: canonicalEventIdHex)
  }

  /// Presents `EventCodeEntryView` in account-sheet mode as a sheet over the
  /// Account sheet — see `AccountSheetView`'s `eventCodeEntrySheetPresented`
  /// binding, analogous to `connectWalletFromAccountSheet()`.
  func openEventCodeEntryFromAccountSheet() {
    eventCodeEntrySheetPresented = true
  }

  @discardableResult
  func requestBluetoothPermission() -> Task<Void, Never> {
    bluetoothMonitor.start()
    let permissionEvaluation = permissionEvaluation
    let bluetoothMonitor = bluetoothMonitor
    return Task { [weak self] in
      let state: BluetoothAuthorizationState
      if let permissionEvaluation {
        state = await permissionEvaluation()
      } else {
        state = await bluetoothMonitor.waitForAuthorizationResolution()
      }
      self?.applyBluetoothState(state)
    }
  }

  func evaluateBluetoothState() {
    applyBluetoothState(bluetoothMonitor.state)
  }

  private func applyBluetoothState(_ state: BluetoothAuthorizationState) {
    guard state != .notDetermined else {
      screen = .bluetoothPermission
      return
    }

    userDefaults.set(true, forKey: Self.hasCompletedOnboardingKey)
    switch state {
    case .denied:
      screen = .bluetoothDenied
    case .poweredOff:
      screen = .bluetoothOff
    case .granted:
      screen = .home
    case .notDetermined:
      screen = .bluetoothPermission
    }
  }

  /// Presents the real WalletConnect pairing flow as a sheet over the
  /// Account sheet — see `AccountSheetView`'s `walletConnectSheetPresented`
  /// binding.
  func connectWalletFromAccountSheet() {
    walletConnectSheetPresented = true
  }

  /// Clears the connected address and resets the recorded connector's local
  /// state back to `.idle` (falling back to `MetaMaskConnector` when no
  /// connector was ever recorded), so reopening the pairing sheet shows
  /// the "Connect Wallet" button again instead of a stale `.connected`
  /// screen. Does not tear down the underlying wallet session with the
  /// wallet (session teardown is out of scope for this slice).
  ///
  /// This is the one production call site that clears the persisted
  /// `CachedWalletHint` (beid#315 / dispatch#26 condition 3) — the
  /// explicit "Disconnect Wallet" action in `AccountSheetView`. Cancel, Try
  /// Again, and Start Over all route through
  /// `WalletConnector.cancelPendingOperation()` instead (dispatch#26
  /// condition 3); the binding sheet's own decline path routes through
  /// `SensingCoordinator.declineBinding()`, which never touches the
  /// connector at all. Neither touches `WalletHintStore`, and
  /// `cancelPendingOperation()` additionally never reaches the wallet
  /// SDK's own persisted session, unlike `disconnect()`.
  func disconnectWallet() {
    walletAddress = nil
    liveWalletAddress = nil
    (walletConnector ?? MetaMaskConnector.shared).disconnect()
    walletConnector = nil
    WalletHintStore().clear()
  }

  // MARK: - Scan flow

  /// The operator origin the preflight reads `Date` from — the event code
  /// lookup template's origin, the same operator the join flow already
  /// depends on. `-beid-clock-preflight-fixture` removes it in DEBUG so a UI
  /// test drives the real controller and shared decision to "undeterminable"
  /// without depending on the network.
  private static func clockPreflightOrigin(bundle: Bundle = .main) -> URL? {
#if DEBUG
    if ProcessInfo.processInfo.arguments.contains("-beid-clock-preflight-fixture") {
      return nil
    }
#endif
    return OperatorDateHeaderSource.origin(
      fromTemplate: bundle.object(forInfoDictionaryKey: "BeidEventCodeLookupURLTemplate") as? String
    )
  }

  func startScan() {
    scanPresented = true
    Task { await clockPreflight.check() }
#if DEBUG
    if ProcessInfo.processInfo.arguments.contains("-beid-clock-preflight-fixture") {
      // Stays on the pre-join Scan screen: no discovery, so the Simulator's
      // DemoEvent script cannot move the phase past it.
      return
    }
    if ProcessInfo.processInfo.arguments.contains("-beid-join-refusal-fixture") {
      sensingCoordinator.injectJoinRefusalForUITesting()
      return
    }
    if ProcessInfo.processInfo.arguments.contains("-beid-continuous-sensing-fixture") {
      sensingCoordinator.injectContinuousSensingForUITesting()
      return
    }
#endif
    // Since beid#410, `startSensing()` correctly starts nothing when no event
    // has been selected. Calling it here had therefore turned Collection's
    // "Sense Event" button into a real-device no-op. This entry point means
    // discovery again: Central-only B005 scanning, with no join or recording.
    sensingCoordinator.startNearbyEventDiscovery()
  }

  func finishScan() {
    cancelPendingJoinAttempt()
    scanPresented = false
    sensingCoordinator.stopNearbyEventDiscovery()
    sensingCoordinator.reset()
  }

  // MARK: - Item detail

  func openProof(_ proof: Proof) {
    selectedProof = proof
  }
}
