// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Screen 04 (+04b empty state): Collection home.
struct CollectionHomeView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

  var body: some View {
    NavigationStack {
      Group {
        if coordinator.proofStore.proofs.isEmpty {
          emptyState
        } else {
          ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
              ForEach(coordinator.proofStore.proofs) { proof in
                Button {
                  coordinator.openProof(proof)
                } label: {
                  ProofCardView(proof: proof)
                }
                .buttonStyle(.plain)
              }
            }
            .padding()
          }
        }
      }
      .navigationTitle("My Proofs")
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            coordinator.accountSheetPresented = true
          } label: {
            Image(systemName: "person.crop.circle")
          }
        }
        ToolbarItem(placement: .bottomBar) {
          Button {
            coordinator.startScan()
          } label: {
            Label("Sense Event", systemImage: "dot.radiowaves.left.and.right")
          }
          .buttonStyle(.borderedProminent)
          .tint(.blue)
        }
      }
      .sheet(isPresented: $coordinator.accountSheetPresented) {
        AccountSheetView()
      }
      .navigationDestination(item: $coordinator.selectedProof) { proof in
        ItemDetailView(proof: proof)
      }
    }
  }

  private var emptyState: some View {
    VStack(spacing: 16) {
      Spacer()
      Image(systemName: "tray")
        .font(.system(size: 48))
        .foregroundStyle(.secondary)
      Text("No proofs yet")
        .font(.title3.weight(.semibold))
      Text("Tap Sense Event to start collecting proof of attendance automatically.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 40)
      Spacer()
      Spacer()
    }
  }
}

#Preview {
  CollectionHomeView().environmentObject(AppCoordinator())
}
