// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Screen 04 (+04b empty state): Collection home.
struct CollectionHomeView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  /// One card per distinct event (beid#217) — grouped by `EventGrouping`
  /// (spec §3), not one card per raw `Proof`. Each group's oldest session
  /// drives artwork (`artworkSeed`); its newest session (`representative`)
  /// drives title/date and is what `openProof(_:)` navigates with (§5.1).
  private struct EventCard: Identifiable {
    let id: UUID
    let representative: Proof
    let artworkSeed: Int
    let sessionCount: Int
  }

  private var eventCards: [EventCard] {
    EventGrouping.groups(from: coordinator.proofStore.proofs).map { group in
      EventCard(
        id: group[0].id,
        representative: group[0],
        artworkSeed: group[group.count - 1].gradientSeed,
        sessionCount: group.count
      )
    }
  }

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
                    ForEach(eventCards) { card in
                      Button {
                        BeidDesign.haptic()
                        coordinator.openProof(card.representative)
                      } label: {
                        ProofCardView(
                          proof: card.representative,
                          artworkSeed: card.artworkSeed,
                          sessionCount: card.sessionCount
                        )
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
        ToolbarItem(placement: .topBarLeading) {
          Button {
            BeidDesign.haptic()
            coordinator.dailySummaryPresented = true
          } label: {
            Image(systemName: "calendar")
          }
          .accessibilityLabel(dailySummaryAccessibilityLabelText)
        }
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
      .navigationDestination(isPresented: $coordinator.dailySummaryPresented) {
        DailySummaryView()
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
      BeidPrimaryButton("Sense event", systemImage: "dot.radiowaves.left.and.right") {
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
      .accessibilityLabel("Sense event")
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

  private var dailySummaryAccessibilityLabelText: String {
    String(
      localized: "collection.dailySummaryButton",
      defaultValue: "Today",
      comment: "Accessibility label for the calendar-icon toolbar button on Collection Home that opens the Daily Summary screen (gh#291) — a day-scoped rollup of proofs collected on the current local calendar day. Same word as the Daily Summary screen's own navigation title, since this button's only purpose is opening that screen."
    )
  }

  private var proofCountText: String {
    String(
      localized: "collection.eventCount",
      defaultValue: "Proof collected from ^[\(eventCards.count) events](inflect: true)",
      comment: "Caption above the Collection Home grid: count of distinct events the user has collected a proof for (grouped by eventCode; each proof recorded before eventCode existed counts as its own event). \"Proof\" here is the mass-noun collected fact, per DESIGN.md §15's vocabulary (a proof is collected — the object of \"collect\" is proof, never the event itself), and the number scopes how many events that applies across; it is not a raw count of recording sessions — a user who scanned the same event twice still counts as one event here, and this caption does not imply exactly one Proof record per event."
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

/// beid#217: a multi-session group (shared `eventCode`) alongside a
/// single-session event, so the `N sessions` card caption (§5.2) and the
/// stable-oldest-session artwork (§5.1) are both visible in preview. The
/// two "ETHGlobal Tokyo" proofs carry deliberately different
/// `gradientSeed`s (mirroring #219's real seed instability across app
/// runs) to make artwork stability visually verifiable here too.
#Preview("Populated with multi-session event") {
  let coordinator = AppCoordinator()
  coordinator.proofStore.add(Proof(
    eventName: "ETHGlobal Tokyo", date: Date().addingTimeInterval(-86400 * 5),
    peersVerified: 3, gradientSeed: 111, eventCode: "ETHTOKYO"
  ))
  coordinator.proofStore.add(Proof(
    eventName: "ETHGlobal Tokyo", date: Date(),
    peersVerified: 5, gradientSeed: 999, eventCode: "ETHTOKYO"
  ))
  coordinator.proofStore.add(Proof(eventName: "Devcon SEA", date: Date().addingTimeInterval(-86400 * 3), peersVerified: 7))
  return CollectionHomeView().environmentObject(coordinator)
}

#Preview("Populated with multi-session event (Dark)") {
  let coordinator = AppCoordinator()
  coordinator.proofStore.add(Proof(
    eventName: "ETHGlobal Tokyo", date: Date().addingTimeInterval(-86400 * 5),
    peersVerified: 3, gradientSeed: 111, eventCode: "ETHTOKYO"
  ))
  coordinator.proofStore.add(Proof(
    eventName: "ETHGlobal Tokyo", date: Date(),
    peersVerified: 5, gradientSeed: 999, eventCode: "ETHTOKYO"
  ))
  coordinator.proofStore.add(Proof(eventName: "Devcon SEA", date: Date().addingTimeInterval(-86400 * 3), peersVerified: 7))
  return CollectionHomeView()
    .environmentObject(coordinator)
    .preferredColorScheme(.dark)
}
