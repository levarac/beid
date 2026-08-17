// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

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
  private func attemptJoinEvent(code rawCode: String) -> EventCodeJoinError? {
    let trimmed = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .emptyCode }
    guard sensingCoordinator.joinEvent(trimmed) else { return .joinFailed }
    return nil
  }

  /// Clears a manually joined event code, mirroring `joinEvent(code:)`.
  func leaveEvent() {
    sensingCoordinator.leaveEvent()
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
    Task {
      try? await Task.sleep(nanoseconds: 300_000_000)
      self.evaluateBluetoothState()
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
