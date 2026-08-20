// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BeidSharedKit
import Foundation

/// Root state machine for onboarding + the collection home. Order of the
/// wallet step is decided once at init from `OnboardingMode.current`; see
/// README "Onboarding flag".
@MainActor
final class AppCoordinator: ObservableObject {
  @Published var screen: AppScreen = .welcome
  @Published var walletAddress: String?
  @Published var scanPresented = false
  @Published var selectedProof: Proof?
  @Published var accountSheetPresented = false
  @Published var walletConnectSheetPresented = false
  @Published var eventCodeEntrySheetPresented = false

  private(set) var walletConnector: (any WalletConnector)?

  let onboardingMode = OnboardingMode.current
  let proofStore: ProofStore
  let registryClient = RegistryDependencies.createClient()
  let sensingCoordinator = SensingCoordinator()
  let bluetoothMonitor = BluetoothMonitor()

  private static let hasCompletedOnboardingKey = "beid.hasCompletedOnboarding"

  init(
    walletConnector: (any WalletConnector)? = nil,
    proofStore: ProofStore? = nil
  ) {
    self.walletConnector = walletConnector
    self.proofStore = proofStore ?? ProofStore()
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
    return UserDefaults.standard.bool(forKey: Self.hasCompletedOnboardingKey)
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

  /// `address` is supplied by the real WalletConnect (Reown) pairing flow
  /// (`WalletConnectPairingView`) once a session settles.
  func completeWalletConnect(address: String, connector: (any WalletConnector)? = nil) {
    recordWalletConnection(address: address, connector: connector)
    screen = .bluetoothPermission
  }

  func recordWalletConnection(address: String, connector: (any WalletConnector)? = nil) {
    if let connector {
      walletConnector = connector
    }
    walletAddress = address
  }

  /// Wallet-optional fallback from `WalletConnectView`'s secondary action:
  /// join an event by manually entered code instead of connecting a wallet.
  func skipWalletForEventCode() {
    screen = .eventCodeEntry
  }

  /// The way back out of `EventCodeEntryView` for a user who doesn't
  /// actually have a code — this is a root-switch screen (not a modal
  /// push), so there is no system back affordance without this.
  func returnToWalletConnect() {
    screen = .walletConnect
  }

  /// Validates and joins the manually entered event code
  /// (`EventCodeEntryView`), calling into the Barnard SDK's join
  /// API via `SensingCoordinator`. On success, advances onboarding exactly
  /// where `completeWalletConnect()` does, without ever setting
  /// `walletAddress`.
  @discardableResult
  func joinEvent(code rawCode: String) -> EventCodeJoinError? {
    if let error = attemptJoinEvent(code: rawCode) { return error }
    screen = .bluetoothPermission
    return nil
  }

  /// Validates and joins the manually entered event code from
  /// `EventCodeEntryView` presented as a sheet over the Account sheet (see
  /// `AccountSheetView`'s `eventCodeEntrySheetPresented` binding). Unlike
  /// `joinEvent(code:)`, success here just dismisses the sheet — it never
  /// touches `screen`, since the user is already past onboarding.
  @discardableResult
  func joinEventFromAccountSheet(code rawCode: String) -> EventCodeJoinError? {
    if let error = attemptJoinEvent(code: rawCode) { return error }
    eventCodeEntrySheetPresented = false
    return nil
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
  private func attemptJoinEvent(code rawCode: String) -> EventCodeJoinError? {
    guard let normalized = BeidSharedKit.event.normalizedEventCodeOrNull(rawEventCode: rawCode) else {
      return .emptyCode
    }
    guard sensingCoordinator.joinEvent(normalized) else { return .joinFailed }
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
  func rejoinPastEvent(code: String) {
    guard sensingCoordinator.joinedEventCode == nil else { return }
    _ = attemptJoinEvent(code: code)
  }

  /// Presents `EventCodeEntryView` in account-sheet mode as a sheet over the
  /// Account sheet — see `AccountSheetView`'s `eventCodeEntrySheetPresented`
  /// binding, analogous to `connectWalletFromAccountSheet()`.
  func openEventCodeEntryFromAccountSheet() {
    eventCodeEntrySheetPresented = true
  }

  func requestBluetoothPermission() {
    bluetoothMonitor.start()
    // Give CoreBluetooth's delegate callback a beat to land before deciding.
    Task { [weak self] in
      try? await Task.sleep(nanoseconds: 300_000_000)
      self?.evaluateBluetoothState()
    }
  }

  func evaluateBluetoothState() {
    UserDefaults.standard.set(true, forKey: Self.hasCompletedOnboardingKey)
    screen = bluetoothMonitor.isPoweredOff ? .bluetoothOff : .home
  }

  /// Presents the real WalletConnect pairing flow as a sheet over the
  /// Account sheet — see `AccountSheetView`'s `walletConnectSheetPresented`
  /// binding.
  func connectWalletFromAccountSheet() {
    walletConnectSheetPresented = true
  }

  /// Clears the connected address and resets `ReownWalletConnectClient`'s
  /// local state back to `.idle`, so reopening the pairing sheet shows the
  /// "Connect Wallet" button again instead of a stale `.connected` screen.
  /// Does not tear down the underlying WalletConnect session with the
  /// wallet (session teardown is out of scope for this slice).
  func disconnectWallet() {
    walletAddress = nil
    (walletConnector ?? ReownWalletConnectClient.shared).disconnect()
    walletConnector = nil
  }

  // MARK: - Scan flow

  func startScan() {
    scanPresented = true
    sensingCoordinator.startSensing()
  }

  func finishScan() {
    scanPresented = false
    sensingCoordinator.reset()
  }

  // MARK: - Item detail

  func openProof(_ proof: Proof) {
    selectedProof = proof
  }
}
