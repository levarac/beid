// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// The connect+binding interstitial (sub-slice 2b,
/// `docs/specs/scan-slice2-redesign.md` §5.6): presented as a sheet over
/// `ScanFlowView` the next time the app becomes active while
/// `SensingCoordinator.bindingState` is `.pendingConnect`. Composed from
/// existing components only — `BeidHeroHeader` + `WalletConnectPairingView`'s
/// provider picker, reused as-is — no Figma frame exists yet for this
/// screen (§9.4: needs design sign-off before a final visual pass; this is
/// the component-composed placeholder the spec explicitly sanctions
/// building ahead of that).
///
/// Wallet is optional (DESIGN.md §1): declining or dismissing at any point
/// leaves `bindingState` at `.pendingConnect` and never touches `phase` —
/// recording keeps running untouched either way.
struct EventBindingSheetView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  @ObservedObject var sensing: SensingCoordinator
  @Environment(\.dismiss) private var dismiss
  /// Observed directly (not just via `coordinator.walletConnector`, which is
  /// only set once a connection is recorded this run) so the restored-hint
  /// fast path below can react to `.restored` immediately on appearance —
  /// dispatch#26 condition 1. Only the production MetaMask path offers this
  /// fast path; `DemoWalletConnector`'s escape hatch below is unaffected.
  @ObservedObject private var metaMaskConnector = MetaMaskConnector.shared
  /// View-local only, mirrors `WalletConnectPairingView`'s own flag — lets
  /// the user bypass the restored-hint suggestion for a fresh connect
  /// without touching `WalletHintStore` (dispatch#26 condition 3).
  @State private var bypassRestoredHint = false

  var body: some View {
    NavigationStack {
      BeidAdaptiveContent {
        VStack(spacing: DS.Space.l) {
          Spacer()
          content
          Spacer()
        }
        .padding(.horizontal, DS.Space.pageMargin)
      }
      .toolbar {
        if showsCancelToolbarButton {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", role: .cancel) {
              sensing.declineBinding()
              dismiss()
            }
          }
        }
      }
      .interactiveDismissDisabled(isInFlight)
      .onDisappear {
        guard case .bound = sensing.bindingState else {
          sensing.declineBinding()
          return
        }
      }
    }
    .tint(DS.Color.actionPrimary)
  }

  private var isInFlight: Bool {
    switch sensing.bindingState {
    case .connecting, .awaitingApproval: true
    case .none, .pendingConnect, .bound, .failed: false
    }
  }

  private var showsCancelToolbarButton: Bool {
    switch sensing.bindingState {
    case .pendingConnect, .failed: true
    case .none, .connecting, .awaitingApproval, .bound: false
    }
  }

  /// The event this attempt is for — carried on `.pendingConnect`, or
  /// (once that case is left behind for `.connecting`/`.awaitingApproval`)
  /// read back off `phase`, which stays `.recording`/`.signalLost` for the
  /// same event throughout the whole attempt.
  private var event: EventSession? {
    if case .pendingConnect(let event) = sensing.bindingState { return event }
    switch sensing.phase {
    case .recording(let event, _), .signalLost(let event, _):
      return event
    case .idle, .sensing, .eventFound:
      return nil
    }
  }

  @ViewBuilder
  private var content: some View {
    switch sensing.bindingState {
    case .none:
      EmptyView()
    case .pendingConnect, .connecting, .awaitingApproval:
      connectContent
    case .bound(let record):
      boundContent(record: record)
    case .failed(let reason):
      failedContent(reason: reason)
    }
  }

  @ViewBuilder
  private var header: some View {
    if let event {
      BeidHeroHeader(
        systemImage: "checkmark.seal",
        title: LocalizedStringKey(eventConfirmedTitle(event: event)),
        subtitle: "Connect a wallet to seal your attendance to this event.",
        tint: DS.Color.actionPrimary
      )
    }
  }

  @ViewBuilder
  private var connectContent: some View {
    header

    if isInFlight {
      ProgressView()
        .tint(DS.Color.actionPrimary)
        .padding(.top, DS.Space.s)
    } else if let address = coordinator.liveWalletAddress, let connector = coordinator.walletConnector {
      // Already connected this run (onboarding, Account sheet, or an
      // earlier binding attempt) — `liveWalletAddress` only ever holds a
      // value that came from a connector's own live session, never a
      // `CachedWalletHint` (beid#315 structural containment).
      BeidPrimaryButton("Seal with connected wallet", systemImage: "checkmark.seal") {
        Task { await performBinding(address: address, connector: connector) }
      }
      .tint(DS.Color.actionPrimary)
    } else if !bypassRestoredHint, case .restored(let hint) = metaMaskConnector.state {
      restoredHintContent(hint: hint)
    } else {
      WalletConnectPairingView { address, connector in
        coordinator.recordWalletConnection(address: address, connector: connector)
        Task { await performBinding(address: address, connector: connector) }
      }
      #if DEBUG
      if sensing.useDemoEventMode {
        BeidSecondaryButton(title: "Simulate binding (Demo)") {
          Task { await simulateDemoBinding() }
        }
        .tint(DS.Color.actionPrimary)
      }
      #endif
    }
  }

  /// dispatch#26 condition 1 (address visible immediately) + condition 2
  /// (collapse connect+sign into one MetaMask round trip when a restored
  /// hint exists) — see `MetaMaskConnector.connectAndSign`'s doc comment
  /// for why the address actually recorded may differ from `hint`.
  private func restoredHintContent(hint: CachedWalletHint) -> some View {
    VStack(spacing: DS.Space.s) {
      Text(LocalizedStringKey(restoredHintSubtitle(hint: hint)))
        .font(DS.Font.meta)
        .foregroundStyle(DS.Color.textSecondary)
        .multilineTextAlignment(.center)

      BeidPrimaryButton(
        LocalizedStringKey(continueAsButtonTitle(hint: hint)),
        systemImage: "checkmark.seal"
      ) {
        Task { await continueFromRestoredHint(hint) }
      }
      .tint(DS.Color.actionPrimary)

      BeidSecondaryButton(title: LocalizedStringKey(connectDifferentWalletTitle)) {
        bypassRestoredHint = true
      }
      .tint(DS.Color.actionPrimary)
    }
  }

  private func boundContent(record: BindingRecord) -> some View {
    VStack(spacing: DS.Space.l) {
      if let event {
        BeidHeroHeader(
          systemImage: "checkmark.seal.fill",
          title: "Sealed",
          subtitle: LocalizedStringKey(sealedSubtitle(event: event)),
          tint: DS.Color.actionPrimary
        )
      }
      BeidPrimaryButton("Done", systemImage: "checkmark") {
        dismiss()
      }
      .tint(DS.Color.actionPrimary)
    }
  }

  private func failedContent(reason: String) -> some View {
    VStack(spacing: DS.Space.l) {
      BeidHeroHeader(
        systemImage: "xmark.octagon.fill",
        title: "Couldn't seal attendance",
        subtitle: "beid couldn't finish sealing your attendance with this wallet.",
        tint: DS.Color.actionPrimary
      )
      Text(verbatim: reason)
        .font(DS.Font.meta)
        .foregroundStyle(DS.Color.textSecondary)
        .multilineTextAlignment(.center)
      BeidSecondaryButton(title: "Try Again") {
        sensing.declineBinding()
      }
      .tint(DS.Color.actionPrimary)
    }
  }

  // MARK: - Binding round trip
  //
  // Two paths, both over the shared `WalletConnector` protocol:
  //
  // - `performBinding` below: two wallet-side approvals (connect, then
  //   sign). Used whenever there is no already-known address to build the
  //   binding message from ahead of time — a fresh `WalletConnectPairingView`
  //   connect, or the DEBUG demo escape hatch.
  // - `continueFromRestoredHint`: one wallet-side approval
  //   (`connectAndSign`), used only when a `.restored` cache hint already
  //   supplies a guessed address to build the message with (dispatch#26
  //   condition 2). `address` passed to `sensing.completeBinding` below is
  //   always taken from the connector's own live result, never from
  //   `hint`/`coordinator.walletAddress` — see `LiveWalletAddress`'s doc
  //   comment in `WalletConnector.swift`.

  @MainActor
  private func performBinding(address: LiveWalletAddress, connector: any WalletConnector) async {
    guard let messageHex = sensing.beginBinding(walletAddress: address.address, chainId: address.chainId) else {
      return
    }
    let result = await connector.requestPersonalSign(messageHex: messageHex) {
      sensing.markBindingAwaitingApproval()
    }
    switch result {
    case .success(let signatureHex):
      completeBindingOrFailVerification(walletAddress: address.address, walletSignatureHex: signatureHex)
    case .failure(let error):
      failBinding(for: error)
    }
  }

  /// dispatch#26 condition 2's collapse: builds the binding message from
  /// the cache hint's guessed address (there is no other address to build
  /// it from before the wallet round trip starts), then dispatches a single
  /// `connectAndSign` trip. The signed message text unavoidably embeds
  /// `hint.address` (the message must exist before the wallet round trip
  /// can start) — so once the wallet reports back which account actually
  /// connected (`live`), the two addresses are compared case-insensitively
  /// (EIP-55 checksum casing can differ between sources without being a
  /// real account change):
  /// - **Match**: `live` signed exactly what was sent; complete as normal.
  /// - **Mismatch** (beid#315 Phase 3): the user switched accounts inside
  ///   the wallet between caching the hint and approving. The signature
  ///   just obtained cannot back a record claiming `live.address` — its
  ///   signed text embeds `hint.address`, not `live.address` — so it must
  ///   not be persisted. The stale pending message (still embedding
  ///   `hint.address`) is discarded and `performBinding` runs the
  ///   two-trip path fresh for `live`, costing one extra wallet approval
  ///   (a `personal_sign`, not a second `connect` — the connector is
  ///   already connected). This still doesn't cryptographically confirm
  ///   the claimed address matches the signature on the match path; that
  ///   remains #316's job (explicitly out of scope here).
  @MainActor
  private func continueFromRestoredHint(_ hint: CachedWalletHint) async {
    guard let messageHex = sensing.beginBinding(walletAddress: hint.address, chainId: hint.chainId) else {
      return
    }
    let result = await metaMaskConnector.connectAndSign(messageHex: messageHex) {
      sensing.markBindingAwaitingApproval()
    }
    switch result {
    case .success(let (live, signatureHex)):
      coordinator.recordWalletConnection(address: live, connector: metaMaskConnector)
      if live.address.caseInsensitiveCompare(hint.address) == .orderedSame {
        completeBindingOrFailVerification(walletAddress: live.address, walletSignatureHex: signatureHex)
      } else {
        sensing.discardPendingBindingMessage()
        await performBinding(address: live, connector: metaMaskConnector)
      }
    case .failure(let error):
      failBinding(for: error)
    }
  }

  /// `sensing.completeBinding` returns `nil` (no state change) both for
  /// stale/malformed inputs and — since beid#316 — a genuine signer
  /// mismatch the coordinator's own verification caught. Before beid#316
  /// only the former could happen here (both call sites above only ever
  /// reach this after a wallet round trip already succeeded), so the `nil`
  /// case was effectively dead code; now it's a realistic outcome, and
  /// without this, `bindingState` would never leave `.connecting`/
  /// `.awaitingApproval`, leaving the sheet stuck on its spinner with no
  /// way to dismiss (`isInFlight` disables swipe-dismiss and hides Cancel
  /// for both those states).
  @MainActor
  private func completeBindingOrFailVerification(walletAddress: String, walletSignatureHex: String) {
    guard sensing.completeBinding(walletAddress: walletAddress, walletSignatureHex: walletSignatureHex) != nil else {
      sensing.failBinding(reason: String(
        localized: "scan.binding.verificationFailed",
        defaultValue: "Couldn't verify this wallet",
        comment: """
        Reason shown when the wallet's signature doesn't match the address it claimed to sign with, so beid \
        could not verify the wallet actually owns that address. The user can try again.
        """
      ))
      return
    }
  }

  private func failBinding(for error: WalletConnectorError) {
    switch error {
    case .rejected:
      sensing.failBinding(reason: String(
        localized: "scan.binding.declined",
        defaultValue: "Declined in wallet",
        comment: "Reason shown when the user's wallet app declines the binding signature request."
      ))
    case .notConnected:
      sensing.failBinding(reason: String(
        localized: "scan.binding.notConnected",
        defaultValue: "Wallet not connected",
        comment: "Reason shown when the binding signature request has no connected wallet session to use."
      ))
    case .timedOut:
      sensing.failBinding(reason: String(
        localized: "scan.binding.timedOut",
        defaultValue: "Wallet did not respond in time",
        comment: "Reason shown when the wallet app never responds to the binding signature request within the timeout."
      ))
    case .relayFailure(let message):
      sensing.failBinding(reason: message)
    case .cancelled:
      // The user stopped this from beid's own UI (Cancel/Try Again/Start
      // Over on the wallet-connect step), not a wallet-side rejection or a
      // stuck request. failedContent's header ("Couldn't seal attendance",
      // a red X) is unconditionally alarming regardless of the reason text
      // below it, so routing this through failBinding(reason:) would tell
      // a user who cancelled themselves that something went wrong.
      // declineBinding() is the same neutral "attempt not completed, no
      // error" transition this sheet's own Cancel toolbar button and
      // swipe-dismiss already use — reuse it instead of inventing new
      // failure chrome for a case that, as of this change, no live Cancel
      // affordance in this screen can actually trigger (see
      // cancelPendingOperation()'s callers).
      //
      // declineBinding() is not just a neutral reset: it also discards
      // pendingBindingMessage. That discard is load-bearing, not
      // incidental — beginBinding() silently reuses a still-present
      // pendingBindingMessage and ignores the address it was just handed,
      // which is exactly the stale-message trap beid#316 exists to close.
      // A cancel that left pendingBindingMessage in place would reopen
      // that trap. Do not replace this with a plain bindingState reset
      // that skips the discard.
      sensing.declineBinding()
    }
  }

  #if DEBUG
  /// Demo-only escape hatch mirroring `SensingCoordinator.useDemoEventMode`
  /// so the whole round trip is exercisable without a real wallet app
  /// installed (task requirement) — connects `DemoWalletConnector` first,
  /// then drives the exact same `performBinding` path as a real provider.
  private func simulateDemoBinding() async {
    await DemoWalletConnector.shared.connect()
    guard case .connected(let address) = DemoWalletConnector.shared.state else { return }
    coordinator.recordWalletConnection(address: address, connector: DemoWalletConnector.shared)
    await performBinding(address: address, connector: DemoWalletConnector.shared)
  }
  #endif

  // MARK: - Localized copy
  //
  // Explicit keys for the two interpolated strings (event name embedded),
  // per AGENTS.md's localization process — a literal-English key containing
  // a placeholder would orphan translations the moment the surrounding
  // English sentence changes. Bridged into `LocalizedStringKey` for
  // `BeidHeroHeader`'s typed API via `LocalizedStringKey(String)`, which
  // renders pre-resolved text as-is (no second catalog lookup match, since
  // the resolved text isn't itself a stored key).

  private func eventConfirmedTitle(event: EventSession) -> String {
    String(
      localized: "scan.binding.title",
      defaultValue: "\(event.name) confirmed",
      comment: "Event name, e.g. 'ETH Tokyo 2026 confirmed' — heading on the wallet connect+binding prompt."
    )
  }

  /// Shared with `WalletConnectPairingView.restoredContent` — same meaning
  /// (a cached address is a reference only, per dispatch#26 condition 4),
  /// same key, reused rather than duplicated per AGENTS.md's key-reuse rule.
  private func restoredHintSubtitle(hint: CachedWalletHint) -> String {
    String(
      localized: "wallet.restored.subtitle",
      defaultValue: "\(hint.truncatedAddress) was used last time — shown for reference. Approve in your wallet to continue.",
      comment: "Subtitle shown under the restored-wallet heading when a cached wallet address exists from a previous launch. %@ is the truncated wallet address, e.g. '0x1234...5678'. This address is a reference only, not a verified signer, until the user approves again in their wallet (dispatch#26 condition 4)."
    )
  }

  private func continueAsButtonTitle(hint: CachedWalletHint) -> String {
    String(
      localized: "wallet.restored.continueButton",
      defaultValue: "Continue as \(hint.truncatedAddress)",
      comment: "Primary button that resumes a previously connected wallet without picking it again. %@ is the truncated wallet address, e.g. '0x1234...5678'."
    )
  }

  private var connectDifferentWalletTitle: String {
    String(
      localized: "wallet.restored.connectDifferent",
      defaultValue: "Connect a different wallet",
      comment: "Secondary button next to a restored-wallet suggestion, for a user who wants to pick a different wallet instead of continuing with the one shown."
    )
  }

  private func sealedSubtitle(event: EventSession) -> String {
    String(
      localized: "scan.binding.sealedSubtitle",
      defaultValue: "Your attendance to \(event.name) is sealed.",
      comment: "Confirmation after the wallet-binding signature succeeds; event name is interpolated, e.g. 'Your attendance to ETH Tokyo 2026 is sealed.'"
    )
  }
}

#Preview("Connect") {
  let coordinator = AppCoordinator()
  coordinator.sensingCoordinator.runDemoSequence(demoEvent: .demoSample, stepDelayNanos: 0)
  return EventBindingSheetView(sensing: coordinator.sensingCoordinator)
    .environmentObject(coordinator)
    .task { await coordinator.sensingCoordinator.waitForDemoSequenceToFinish() }
}

#Preview("Connect (Dark)") {
  let coordinator = AppCoordinator()
  coordinator.sensingCoordinator.runDemoSequence(demoEvent: .demoSample, stepDelayNanos: 0)
  return EventBindingSheetView(sensing: coordinator.sensingCoordinator)
    .environmentObject(coordinator)
    .task { await coordinator.sensingCoordinator.waitForDemoSequenceToFinish() }
    .preferredColorScheme(.dark)
}

#Preview("Already connected") {
  let coordinator = AppCoordinator()
  coordinator.recordWalletConnection(
    address: LiveWalletAddress.fromConnectorResult(
      address: "0x1234567890abcdef1234567890abcdef12345678",
      chainId: "eip155:1"
    ),
    connector: DemoWalletConnector.shared
  )
  coordinator.sensingCoordinator.runDemoSequence(demoEvent: .demoSample, stepDelayNanos: 0)
  return EventBindingSheetView(sensing: coordinator.sensingCoordinator)
    .environmentObject(coordinator)
    .task { await coordinator.sensingCoordinator.waitForDemoSequenceToFinish() }
}

#Preview("Already connected (Dark)") {
  let coordinator = AppCoordinator()
  coordinator.recordWalletConnection(
    address: LiveWalletAddress.fromConnectorResult(
      address: "0x1234567890abcdef1234567890abcdef12345678",
      chainId: "eip155:1"
    ),
    connector: DemoWalletConnector.shared
  )
  coordinator.sensingCoordinator.runDemoSequence(demoEvent: .demoSample, stepDelayNanos: 0)
  return EventBindingSheetView(sensing: coordinator.sensingCoordinator)
    .environmentObject(coordinator)
    .task { await coordinator.sensingCoordinator.waitForDemoSequenceToFinish() }
    .preferredColorScheme(.dark)
}
