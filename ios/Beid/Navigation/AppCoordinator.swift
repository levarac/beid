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

  /// `address` is supplied by the real WalletConnect (Reown) flow when
  /// `WalletConnectMode.current == .reown`; the stub path calls this with
  /// no argument, unchanged from before the spike.
  func completeWalletConnect(address: String? = nil) {
    walletAddress = address ?? WalletConnectStub.fakeConnect()
    screen = .bluetoothPermission
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
