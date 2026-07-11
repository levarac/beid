// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Screen 04 (+04b empty state): Collection home.
struct CollectionHomeView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  private var columns: [GridItem] {
    [GridItem(
      .adaptive(minimum: horizontalSizeClass == .regular
        ? DS.Layout.regularGridCardMinimumWidth
        : DS.Layout.compactGridCardMinimumWidth),
      spacing: DS.Space.m
    )]
  }

  var body: some View {
    NavigationStack {
      ZStack {
        DS.Color.surfaceCanvas
          .ignoresSafeArea()

        ScrollView {
          BeidAdaptiveContent(regularMaxWidth: DS.Layout.collectionContentMaxWidth) {
            VStack(alignment: .leading) {
              if coordinator.proofStore.proofs.isEmpty {
                emptyState
              } else {
                LazyVGrid(columns: columns, spacing: DS.Space.m) {
                  ForEach(coordinator.proofStore.proofs) { proof in
                    Button {
                      BeidDesign.haptic()
                      coordinator.openProof(proof)
                    } label: {
                      ProofCardView(proof: proof)
                    }
                    .buttonStyle(.plain)
                  }
                }
              }
            }
          }
        }
        .contentMargins(.horizontal, BeidDesign.Spacing.screenHorizontal, for: .scrollContent)
        .contentMargins(.vertical, 18, for: .scrollContent)
      }
      .navigationTitle("My Proofs")
      .navigationBarTitleDisplayMode(.large)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            BeidDesign.haptic()
            coordinator.accountSheetPresented = true
          } label: {
            Image(systemName: "person.crop.circle")
          }
          .accessibilityLabel("Account")
        }
      }
      .safeAreaInset(edge: .bottom) {
        BeidAdaptiveContent {
          BeidPrimaryButton("Sense Event", systemImage: "dot.radiowaves.left.and.right") {
            coordinator.startScan()
          }
          .padding(.horizontal, BeidDesign.Spacing.screenHorizontal)
          .padding(.vertical, DS.Space.s)
        }
        .background(.bar)
      }
      .sheet(isPresented: $coordinator.accountSheetPresented) {
        AccountSheetView()
          .presentationDetents([.medium])
          .presentationDragIndicator(.visible)
      }
      .navigationDestination(item: $coordinator.selectedProof) { proof in
        ItemDetailView(proof: proof)
      }
    }
  }

  private var emptyState: some View {
    VStack {
      Spacer(minLength: 96)
      BeidPanel {
        VStack(alignment: .leading, spacing: BeidDesign.Spacing.content) {
          BeidGlyph(systemImage: "tray", tint: .secondary, size: 64)
          Text("No proofs yet")
            .font(DS.Font.sectionTitle)
          Text("Tap Sense Event to start collecting proof of attendance automatically.")
            .font(DS.Font.body)
            .foregroundStyle(DS.Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 140)
    }
  }
}

#Preview {
  CollectionHomeView().environmentObject(AppCoordinator())
}
