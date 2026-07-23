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

  private(set) var walletConnector: (any WalletConnector)?

  let onboardingMode = OnboardingMode.current
  let proofStore: ProofStore
  let sensingCoordinator = SensingCoordinator()
  let bluetoothMonitor = BluetoothMonitor()

  init(
    walletConnector: (any WalletConnector)? = nil,
    proofStore: ProofStore? = nil
  ) {
    self.walletConnector = walletConnector
    self.proofStore = proofStore ?? ProofStore()
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

  // MARK: - Proof signing

  /// Drives `proof.signatureState` through the wallet-signing lifecycle by
  /// reusing the already-connected WalletConnect session (never opens a
  /// second pairing flow — see `ReownWalletConnectClient.requestPersonalSign`).
  /// Callers MUST only offer this action when `walletAddress != nil`; the
  /// underlying `Proof` in `proofStore` is never touched beyond its
  /// `signatureState` field, regardless of outcome.
  func signProof(_ proof: Proof) async {
    guard let walletAddress, let walletConnector else { return }

    // Reentrancy guard: `ProofSignatureControlsView` already hides the
    // "Sign this proof" action while a request is in flight, but that's a
    // reactive re-render, not a lock — two rapid taps in the same runloop
    // tick can both read the pre-tap state before either write lands. Bail
    // out here so at most one `personal_sign` request is ever in flight
    // for a given proof.
    switch proofStore.proof(withId: proof.id)?.signatureState {
    case .connecting, .awaitingApproval:
      return
    default:
      break
    }

    proofStore.updateSignatureState(for: proof.id, to: .connecting)

    let chainId = walletConnector.chainId
    let payload = SignaturePayload(proof: proof, chainId: chainId)

    let digestHex: String
    do {
      digestHex = try payload.signingDigestHex()
    } catch {
      proofStore.updateSignatureState(for: proof.id, to: .failed(reason: error.localizedDescription))
      return
    }

    let result = await walletConnector.requestPersonalSign(digestHex: digestHex) { [weak self] in
      self?.proofStore.updateSignatureState(for: proof.id, to: .awaitingApproval)
    }

    switch result {
    case .success(let signatureHex):
      let record = SignatureRecord(
        signerAddress: walletAddress,
        signatureHex: signatureHex,
        payload: payload,
        signedAt: Date()
      )
      proofStore.updateSignatureState(for: proof.id, to: .signed(record))
    case .failure(.notConnected):
      proofStore.updateSignatureState(for: proof.id, to: .failed(reason: "No connected wallet"))
    case .failure(.rejected):
      proofStore.updateSignatureState(for: proof.id, to: .rejected)
    case .failure(.timedOut):
      proofStore.updateSignatureState(for: proof.id, to: .deferred)
    case .failure(.relayFailure(let message)):
      proofStore.updateSignatureState(for: proof.id, to: .failed(reason: message))
    }
  }
}
