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
    } else if let address = coordinator.walletAddress, let connector = coordinator.walletConnector {
      BeidPrimaryButton("Seal with connected wallet", systemImage: "checkmark.seal") {
        Task { await performBinding(address: address, connector: connector) }
      }
      .tint(DS.Color.actionPrimary)
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
  // Two wallet-side approvals (connect, then sign) over the existing
  // `WalletConnector` protocol — the pinned Coinbase Wallet Mobile SDK
  // can't bundle `personal_sign` into `initiateHandshake(initialActions:)`
  // without already knowing the address it would sign for, and Reown has no
  // bundled connect+sign RPC at all, so a uniform 2-step round trip (rather
  // than a per-provider special case) is what's actually available through
  // the shared connector surface `WalletConnectPairingView` already reuses.

  @MainActor
  private func performBinding(address: String, connector: any WalletConnector) async {
    guard let digestHex = sensing.beginBinding() else { return }
    let result = await connector.requestPersonalSign(digestHex: digestHex) {
      sensing.markBindingAwaitingApproval()
    }
    switch result {
    case .success(let signatureHex):
      sensing.completeBinding(walletAddress: address, walletSignatureHex: signatureHex)
    case .failure(.rejected):
      sensing.failBinding(reason: String(
        localized: "scan.binding.declined",
        defaultValue: "Declined in wallet",
        comment: "Reason shown when the user's wallet app declines the binding signature request."
      ))
    case .failure(.notConnected):
      sensing.failBinding(reason: String(
        localized: "scan.binding.notConnected",
        defaultValue: "Wallet not connected",
        comment: "Reason shown when the binding signature request has no connected wallet session to use."
      ))
    case .failure(.timedOut):
      sensing.failBinding(reason: String(
        localized: "scan.binding.timedOut",
        defaultValue: "Wallet did not respond in time",
        comment: "Reason shown when the wallet app never responds to the binding signature request within the timeout."
      ))
    case .failure(.relayFailure(let message)):
      sensing.failBinding(reason: message)
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
  coordinator.walletAddress = "0x1234567890abcdef1234567890abcdef12345678"
  coordinator.sensingCoordinator.runDemoSequence(demoEvent: .demoSample, stepDelayNanos: 0)
  return EventBindingSheetView(sensing: coordinator.sensingCoordinator)
    .environmentObject(coordinator)
    .task { await coordinator.sensingCoordinator.waitForDemoSequenceToFinish() }
}

#Preview("Already connected (Dark)") {
  let coordinator = AppCoordinator()
  coordinator.walletAddress = "0x1234567890abcdef1234567890abcdef12345678"
  coordinator.sensingCoordinator.runDemoSequence(demoEvent: .demoSample, stepDelayNanos: 0)
  return EventBindingSheetView(sensing: coordinator.sensingCoordinator)
    .environmentObject(coordinator)
    .task { await coordinator.sensingCoordinator.waitForDemoSequenceToFinish() }
    .preferredColorScheme(.dark)
}
