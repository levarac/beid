// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Real WalletConnect (Reown) pairing UI — shown from `WalletConnectView`
/// when `WalletConnectMode.current == .reown`. Spike implementation; see
/// ios/README.md "WalletConnect (spike)" for what this does and doesn't do.
struct ReownWalletConnectView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  @StateObject private var client = ReownWalletConnectClient.shared

  var body: some View {
    VStack(spacing: 24) {
      Spacer()

      switch client.state {
      case .notConfigured:
        notConfiguredContent

      case .idle:
        idleContent

      case .awaitingApproval(let uri):
        awaitingApprovalContent(uri: uri)

      case .connected(let address):
        connectedContent(address: address)

      case .failed(let message):
        failedContent(message: message)
      }

      Spacer()
    }
    .padding(.horizontal, 32)
    .task {
      client.configureIfNeeded()
    }
    .onChange(of: client.state) { _, newState in
      if case .connected(let address) = newState {
        coordinator.completeWalletConnect(address: address)
      }
    }
  }

  private var notConfiguredContent: some View {
    VStack(spacing: 16) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 44))
        .foregroundStyle(.orange)
      Text("WalletConnect not configured")
        .font(.headline)
      Text("No Reown Cloud project ID found. Copy ios/Secrets.example.plist to ios/Beid/Secrets.plist and fill in PROJECT_ID — see ios/README.md \u{201C}WalletConnect (spike)\u{201D}.")
        .font(.subheadline)
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
    }
  }

  private var idleContent: some View {
    VStack(spacing: 16) {
      Image(systemName: "wallet.pass.fill")
        .font(.system(size: 56))
        .foregroundStyle(.blue)
      Text("Connect Your Wallet")
        .font(.title2.bold())
      Text("Real WalletConnect pairing (spike). Generates a live pairing URI over the Reown relay.")
        .font(.subheadline)
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)

      Button {
        Task { await client.connect() }
      } label: {
        Text("Generate Pairing URI")
          .font(.headline)
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .tint(.blue)
      .padding(.top, 8)
    }
  }

  private func awaitingApprovalContent(uri: String) -> some View {
    VStack(spacing: 16) {
      Text("Scan with a WalletConnect-compatible wallet")
        .font(.headline)
        .multilineTextAlignment(.center)

      if let qrImage = QRCodeRenderer.image(for: uri) {
        qrImage
          .interpolation(.none)
          .resizable()
          .scaledToFit()
          .frame(width: 220, height: 220)
          .padding(8)
          .background(Color.white)
          .clipShape(RoundedRectangle(cornerRadius: 12))
      }

      Text(uri)
        .font(.caption.monospaced())
        .lineLimit(3)
        .truncationMode(.middle)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)

      Button("Copy URI") {
        UIPasteboard.general.string = uri
      }
      .buttonStyle(.bordered)

      ProgressView("Waiting for wallet to approve\u{2026}")
        .padding(.top, 8)

      Button("Cancel", role: .cancel) {
        client.reset()
      }
      .padding(.top, 4)
    }
  }

  private func connectedContent(address: String) -> some View {
    VStack(spacing: 16) {
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 56))
        .foregroundStyle(.green)
      Text("Connected")
        .font(.title2.bold())
      Text(address)
        .font(.subheadline.monospaced())
        .foregroundStyle(.secondary)
    }
  }

  private func failedContent(message: String) -> some View {
    VStack(spacing: 16) {
      Image(systemName: "xmark.octagon.fill")
        .font(.system(size: 44))
        .foregroundStyle(.red)
      Text("Connection failed")
        .font(.headline)
      Text(message)
        .font(.subheadline)
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
      Button("Try Again") {
        client.reset()
      }
      .buttonStyle(.bordered)
    }
  }
}

#Preview {
  ReownWalletConnectView().environmentObject(AppCoordinator())
}
