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
              ContinuousSensingStatus(sensing: coordinator.sensingCoordinator)

              if coordinator.proofStore.proofs.isEmpty {
                emptyState
              } else {
                Text(proofCountText)
                  .font(DS.Font.supporting)
                  .foregroundStyle(DS.Color.textSecondary)
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
        .contentMargins(.horizontal, DS.Space.pageMargin, for: .scrollContent)
        .contentMargins(.vertical, DS.Space.m, for: .scrollContent)
      }
      .navigationTitle("Collection")
      .navigationBarTitleDisplayMode(.large)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          BeidTextControl("collection.dailySummaryButton", accessibilityLabel: "collection.dailySummaryButton") {
            coordinator.dailySummaryPresented = true
          }
        }
        .beidWithoutSharedBackground()
        ToolbarItem(placement: .topBarTrailing) {
          BeidTextControl("Account", accessibilityLabel: "Account") {
            coordinator.accountSheetPresented = true
          }
        }
        .beidWithoutSharedBackground()
      }
      .safeAreaInset(edge: .bottom) {
        BeidAdaptiveContent {
          scanButton
            .padding(.horizontal, DS.Space.pageMargin)
            .padding(.vertical, DS.Space.s)
        }
        .beidBottomBar()
      }
      .sheet(isPresented: $coordinator.accountSheetPresented) {
        AccountSheetView()
          .environmentObject(coordinator)
          // Frame 10 is 474pt high on the 402×874 reference. The system's
          // medium detent starts ~15pt too low on the PM's iPhone 17 Pro;
          // this fraction brings the sheet top near Figma's y=400.
          .presentationDetents([.fraction(0.53)])
          .presentationDragIndicator(.visible)
          // Sheets don't inherit the presenter's .tint (unlike push
          // navigation) — without this, the Done/Connect Wallet buttons
          // render system blue. Same fix as AccountSheetView's own
          // WalletConnectSheetView doc comment already describes.
          .tint(DS.Color.actionPrimary)
          .presentationBackground(DS.Color.textPrimary)
      }
      .navigationDestination(isPresented: $coordinator.dailySummaryPresented) {
        DailySummaryView()
      }
      .navigationDestination(item: $coordinator.selectedProof) { proof in
        ItemDetailView(proof: proof)
      }
    }
  }

  /// The empty state keeps the primary CTA. Once proofs exist, the same
  /// action stays available as a text control in the bottom bar.
  @ViewBuilder
  private var scanButton: some View {
    if coordinator.proofStore.proofs.isEmpty {
      BeidPrimaryButton("Sense Event") {
        coordinator.startScan()
      }
    } else {
      BeidTextControl("Sense Event", accessibilityLabel: "Sense Event") {
        coordinator.startScan()
      }
    }
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
      BeidEmptyBlock {
        VStack(alignment: .leading, spacing: DS.Space.m) {
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

/// Compact home-surface status for sensing that continues after the scan
/// sheet closes (beid#200). This is a separate observed view because
/// `AppCoordinator` intentionally does not republish nested sensing state.
private struct ContinuousSensingStatus: View {
  @ObservedObject var sensing: SensingCoordinator

  var body: some View {
    if isSensing {
      BeidPanel {
        HStack(spacing: DS.Space.m) {
          Text("Sensing continues in background")
            .font(DS.Font.supporting)
            .foregroundStyle(DS.Color.textPrimary)
            .accessibilityIdentifier("collection.continuous-sensing")

          Spacer(minLength: DS.Space.s)

          Button("Stop sensing") {
            sensing.stopSensing()
          }
          .font(DS.Font.meta)
          .buttonStyle(.bordered)
          .accessibilityIdentifier("collection.stop-sensing")
        }
      }
    }
  }

  private var isSensing: Bool {
    sensing.isScanning || sensing.isAdvertising
  }
}

#Preview("Empty") {
  CollectionHomeView().environmentObject(AppCoordinator())
}

#Preview("Populated") {
  let coordinator = AppCoordinator()
  coordinator.proofStore.add(Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 3))
  coordinator.proofStore.add(Proof(eventName: "Devcon SEA", date: Date().addingTimeInterval(-86400 * 3), peersVerified: 7))
  coordinator.proofStore.add(Proof(eventName: "beid Meetup", date: Date().addingTimeInterval(-86400 * 30), peersVerified: 1))
  return CollectionHomeView().environmentObject(coordinator)
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
