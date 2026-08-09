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
            VStack(alignment: .leading, spacing: DS.Space.m) {
              if coordinator.proofStore.proofs.isEmpty {
                emptyState
              } else {
                Text(proofCountText)
                  .font(DS.Font.supporting)
                  .foregroundStyle(DS.Color.textSecondary)
                BeidGlassGroup(spacing: DS.Space.m) {
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
        }
        .contentMargins(.horizontal, BeidDesign.Spacing.screenHorizontal, for: .scrollContent)
        .contentMargins(.vertical, DS.Space.m, for: .scrollContent)
      }
      .navigationTitle("Collection")
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
          scanButton
            .padding(.horizontal, BeidDesign.Spacing.screenHorizontal)
            .padding(.vertical, DS.Space.s)
        }
        .background(.bar)
      }
      .sheet(isPresented: $coordinator.accountSheetPresented) {
        AccountSheetView()
          .presentationDetents([.medium])
          .presentationDragIndicator(.visible)
          // Sheets don't inherit the presenter's .tint (unlike push
          // navigation) — without this, the Done/Connect Wallet buttons
          // render system blue. Same fix as AccountSheetView's own
          // WalletConnectSheetView doc comment already describes.
          .tint(DS.Color.actionPrimary)
      }
      .navigationDestination(item: $coordinator.selectedProof) { proof in
        ItemDetailView(proof: proof)
      }
    }
  }

  /// Icon-only once proofs exist (dense grid, per the approved 04 redesign);
  /// the empty state keeps a labeled CTA for first-run discoverability
  /// (DESIGN.md §3) — same `startScan()` action and localized "Sense Event"
  /// string either way, only the visible label differs.
  @ViewBuilder
  private var scanButton: some View {
    if coordinator.proofStore.proofs.isEmpty {
      BeidPrimaryButton("Sense Event", systemImage: "dot.radiowaves.left.and.right") {
        coordinator.startScan()
      }
    } else {
      Group {
        if #available(iOS 26.0, *) {
          Button(action: startScan, label: scanIcon)
            .buttonStyle(.glassProminent)
        } else {
          Button(action: startScan, label: scanIcon)
            .buttonStyle(.borderedProminent)
        }
      }
      .buttonBorderShape(.circle)
      .accessibilityLabel("Sense Event")
    }
  }

  private func scanIcon() -> some View {
    Image(systemName: "dot.radiowaves.left.and.right")
      .font(DS.Font.cta)
      .foregroundStyle(DS.Color.surfaceCanvas)
      .frame(width: DS.Size.minHitTarget, height: DS.Size.minHitTarget)
  }

  private func startScan() {
    BeidDesign.haptic()
    coordinator.startScan()
  }

  private var proofCountText: String {
    String(
      localized: "collection.proofCount",
      defaultValue: "\(coordinator.proofStore.proofs.count) proofs collected",
      comment: "Caption above the Collection Home grid, showing how many proofs the user has collected so far."
    )
  }

  private var emptyState: some View {
    VStack {
      Spacer()
      BeidPanel {
        VStack(alignment: .leading, spacing: BeidDesign.Spacing.content) {
          // TODO(asset): encounter-field-empty
          BeidGlyph(systemImage: "tray", assetImage: "encounter-field-empty", tint: .secondary, size: 32)
          Text("No proofs yet")
            .font(DS.Font.sectionTitle)
          Text("Start sensing at an event to collect your first proof.")
            .font(DS.Font.body)
            .foregroundStyle(DS.Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer()
    }
  }
}

#Preview("Empty") {
  CollectionHomeView().environmentObject(AppCoordinator())
}

#Preview("Empty (Dark)") {
  CollectionHomeView()
    .environmentObject(AppCoordinator())
    .preferredColorScheme(.dark)
}

#Preview("Populated") {
  let coordinator = AppCoordinator()
  coordinator.proofStore.add(Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 3))
  coordinator.proofStore.add(Proof(eventName: "Devcon SEA", date: Date().addingTimeInterval(-86400 * 3), peersVerified: 7))
  coordinator.proofStore.add(Proof(eventName: "beid Meetup", date: Date().addingTimeInterval(-86400 * 30), peersVerified: 1))
  return CollectionHomeView().environmentObject(coordinator)
}

#Preview("Populated (Dark)") {
  let coordinator = AppCoordinator()
  coordinator.proofStore.add(Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 3))
  coordinator.proofStore.add(Proof(eventName: "Devcon SEA", date: Date().addingTimeInterval(-86400 * 3), peersVerified: 7))
  return CollectionHomeView()
    .environmentObject(coordinator)
    .preferredColorScheme(.dark)
}
