// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Wallet-signing status + action for one `Proof`. Shared by
/// `ProofCollectedView` and `ItemDetailView` — see DESIGN.md §10
/// "Component: ProofSignatureControlsView".
///
/// Looks up `signatureState` live from `AppCoordinator.proofStore` on every
/// render rather than taking a `Proof` snapshot: a sign attempt mutates
/// state while this view stays on screen, and a stale snapshot would never
/// show `connecting` → `awaitingApproval` → `signed` progressing.
struct ProofSignatureControlsView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  let proofId: UUID

  private var proof: Proof? {
    coordinator.proofStore.proof(withId: proofId)
  }

  var body: some View {
    if let proof {
      VStack(alignment: .leading, spacing: DS.Space.m) {
        statusRow(for: proof.signatureState)
        detail(for: proof.signatureState)
        action(for: proof)
      }
    }
  }

  @ViewBuilder
  private func statusRow(for state: ProofSignatureState) -> some View {
    switch state {
    case .notRequested:
      BeidMetricRow(label: "Signature", value: "Not signed", valueStyle: AnyShapeStyle(DS.Color.textSecondary))
    case .connecting, .awaitingApproval:
      HStack(spacing: DS.Space.s) {
        ProgressView()
          .tint(DS.Color.actionPrimary)
        Text(progressLabel(for: state))
          .font(DS.Font.supporting)
          .foregroundStyle(DS.Color.textSecondary)
      }
    case .signed:
      BeidMetricRow(label: "Signature", value: "Signed", valueStyle: AnyShapeStyle(DS.Color.proofSeal))
    case .deferred:
      BeidMetricRow(label: "Signature", value: "Signing deferred", valueStyle: AnyShapeStyle(DS.Color.statusCaution))
    case .rejected:
      BeidMetricRow(label: "Signature", value: "Signing declined", valueStyle: AnyShapeStyle(DS.Color.statusCaution))
    case .failed:
      BeidMetricRow(label: "Signature", value: "Signing failed", valueStyle: AnyShapeStyle(DS.Color.statusCaution))
    }
  }

  private func progressLabel(for state: ProofSignatureState) -> LocalizedStringKey {
    if case .awaitingApproval = state {
      return "Waiting for wallet to approve…"
    }
    return "Connecting to wallet…"
  }

  @ViewBuilder
  private func detail(for state: ProofSignatureState) -> some View {
    switch state {
    case .signed(let record):
      Text(verbatim: truncated(record.signerAddress))
        .font(DS.Font.ledgerMono)
        .foregroundStyle(DS.Color.textSecondary)
    case .rejected:
      Text("You declined the request in your wallet.")
        .font(DS.Font.meta)
        .foregroundStyle(DS.Color.textSecondary)
    case .deferred:
      Text("The request timed out. Try again once your wallet is reachable.")
        .font(DS.Font.meta)
        .foregroundStyle(DS.Color.textSecondary)
    case .failed(let reason):
      Text(verbatim: reason)
        .font(DS.Font.meta)
        .foregroundStyle(DS.Color.textSecondary)
    case .notRequested, .connecting, .awaitingApproval:
      EmptyView()
    }
  }

  @ViewBuilder
  private func action(for proof: Proof) -> some View {
    switch proof.signatureState {
    case .connecting, .awaitingApproval, .signed:
      EmptyView()
    case .notRequested, .deferred, .rejected, .failed:
      if coordinator.walletAddress != nil {
        BeidSecondaryButton(title: "Sign this proof") {
          Task { await coordinator.signProof(proof) }
        }
        .tint(DS.Color.actionPrimary)
      } else {
        BeidSecondaryButton(title: "Connect Wallet") {
          coordinator.accountSheetPresented = true
        }
        .tint(DS.Color.actionPrimary)
      }
    }
  }

  private func truncated(_ address: String) -> String {
    guard address.count > 10 else { return address }
    return "\(address.prefix(6))...\(address.suffix(4))"
  }
}

#Preview("Not signed, wallet connected") {
  let coordinator = AppCoordinator()
  let proof = Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 3)
  coordinator.proofStore.add(proof)
  coordinator.walletAddress = "0x1234567890abcdef1234567890abcdef12345678"
  return BeidPanel {
    ProofSignatureControlsView(proofId: proof.id)
  }
  .padding()
  .environmentObject(coordinator)
}

#Preview("No wallet connected") {
  let coordinator = AppCoordinator()
  let proof = Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 3)
  coordinator.proofStore.add(proof)
  return BeidPanel {
    ProofSignatureControlsView(proofId: proof.id)
  }
  .padding()
  .environmentObject(coordinator)
}

#Preview("Signed") {
  let coordinator = AppCoordinator()
  var proof = Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 3)
  let payload = SignaturePayload(proof: proof, chainId: "eip155:1")
  proof.signatureState = .signed(SignatureRecord(
    signerAddress: "0x1234567890abcdef1234567890abcdef12345678",
    signatureHex: "0xdeadbeef",
    payload: payload,
    signedAt: Date()
  ))
  coordinator.proofStore.add(proof)
  coordinator.walletAddress = "0x1234567890abcdef1234567890abcdef12345678"
  return BeidPanel {
    ProofSignatureControlsView(proofId: proof.id)
  }
  .padding()
  .environmentObject(coordinator)
}

#Preview("Rejected") {
  let coordinator = AppCoordinator()
  var proof = Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 3)
  proof.signatureState = .rejected
  coordinator.proofStore.add(proof)
  coordinator.walletAddress = "0x1234567890abcdef1234567890abcdef12345678"
  return BeidPanel {
    ProofSignatureControlsView(proofId: proof.id)
  }
  .padding()
  .environmentObject(coordinator)
}
