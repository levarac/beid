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

  let onboardingMode = OnboardingMode.current
  let proofStore = ProofStore()
  let sensingCoordinator = SensingCoordinator()
  let bluetoothMonitor = BluetoothMonitor()

  init() {
    sensingCoordinator.onProofCollected = { [weak self] proof in
      self?.proofStore.add(proof)
    }
  }

  // MARK: - Onboarding

  func beginOnboarding() {
    switch onboardingMode {
    case .walletFirst:
      screen = .walletConnect
    case .guestFirst:
      screen = .bluetoothPermission
    }
  }

  func completeWalletConnect() {
    walletAddress = WalletConnectStub.fakeConnect()
    screen = .bluetoothPermission
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
  /// (`EventCodeEntryView`), calling into the vendored Barnard SDK's join
  /// API via `SensingCoordinator`. On success, advances onboarding exactly
  /// where `completeWalletConnect()` does, without ever setting
  /// `walletAddress`.
  @discardableResult
  func joinEvent(code rawCode: String) -> EventCodeJoinError? {
    let trimmed = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .emptyCode }
    guard sensingCoordinator.joinEvent(trimmed) else { return .joinFailed }
    screen = .bluetoothPermission
    return nil
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
    screen = bluetoothMonitor.isPoweredOff ? .bluetoothOff : .home
  }

  func connectWalletFromAccountSheet() {
    walletAddress = WalletConnectStub.fakeConnect()
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
