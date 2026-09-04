// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// gh#230 — reduced version of gh#141: list events this device has
/// previously joined and recorded a `Proof` for, tap one to rejoin without
/// retyping the code. Pushed from `AccountSheetView` via `NavigationLink`,
/// matching the "Venue Device" sub-screen precedent
/// (`docs/specs/participation-surface.md` §5.3 used the same placement
/// reasoning for a different screen) rather than an inline `List` section —
/// this list grows for as long as the app is used (one entry per distinct
/// event ever joined), where "Venue Device" and the other Account rows are
/// fixed in count.
///
/// Deliberately reuses `AccountSheetView`'s own plain `List`/`Section`/
/// `Label`/`Button` idiom, the same one `VenueDeviceOrganizerView`'s history
/// list already uses for a "past records, tap for detail/no detail" list.
/// Does **not** use `EventCardView` — its `Badge` vocabulary
/// (`.detected`/`.recording`/`.paused`) is tied to the live scan-phase
/// machine, and none of those states honestly describe "a past event, tap
/// to rejoin" (2026-08-19 DECISIONS "#141 は縮小版で先に進める": no new
/// visual design for this reduced slice; cards stay Figma-gated for full
/// #141). "Current" below is a plain state marker of the app's own already-
/// known state, not a "verified"-shaped claim about an external authority.
struct PastEventsView: View {
  @ObservedObject var sensingCoordinator: SensingCoordinator
  @ObservedObject var proofStore: ProofStore
  let onRejoin: (String) -> Void

  private var pastEvents: [Proof] {
    EventGrouping.pastEvents(from: proofStore.proofs)
  }

  var body: some View {
    List {
      Section {
        if pastEvents.isEmpty {
          Text(
            "No past events yet.",
            comment: "Empty state on the Past Events screen, shown when this device has never recorded a Proof for any event."
          )
          .font(DS.Font.supporting)
          .foregroundStyle(DS.Color.textSecondary)
        } else {
          ForEach(pastEvents) { proof in
            row(for: proof)
          }
        }
      } footer: {
        Text(
          "Only events you've actually recorded a proof for are listed here.",
          comment: "Footer under the Past Events list, clarifying that a code that was typed and abandoned before recording completed does not appear."
        )
      }
    }
    .scrollContentBackground(.hidden)
    .background(DS.Color.surfaceCanvas)
    .navigationTitle(navigationTitle)
    .navigationBarTitleDisplayMode(.inline)
  }

  /// The navigation title keeps its title-style noun phrase, separate from
  /// the Account sheet's sentence-case action label.
  private var navigationTitle: String {
    String(localized: "account.pastEvents.title", defaultValue: "Past Events")
  }

  @ViewBuilder
  private func row(for proof: Proof) -> some View {
    // `pastEvents` only ever returns proofs with a non-nil eventCode
    // (EventGrouping.pastEvents's own contract) — force-unwrap here would
    // still be defensive-coding-for-the-impossible, so guard instead and
    // simply omit a row this invariant says can't occur, rather than crash
    // if it somehow did.
    if let eventCode = proof.eventCode {
      let isCurrent = eventCode == sensingCoordinator.joinedEventCode
      Button {
        BeidDesign.haptic()
        onRejoin(eventCode)
      } label: {
        HStack(spacing: DS.Space.m) {
          Label {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
              Text(proof.eventName)
                .font(DS.Font.cardTitle)
                .foregroundStyle(DS.Color.textPrimary)
              Text(proof.date.formatted(date: .abbreviated, time: .shortened))
                .font(DS.Font.supporting)
                .foregroundStyle(DS.Color.textSecondary)
            }
          } icon: {
            Image(systemName: "clock.arrow.circlepath")
          }

          Spacer()

          if isCurrent {
            Text(
              "Current",
              comment: "Trailing label on the Past Events row for the event this device is presently joined to — a plain state marker, not an external verification claim."
            )
            .font(DS.Font.meta)
            .foregroundStyle(DS.Color.statusOn)
          }
        }
      }
      // Matches "Join Event"'s existing single-slot invariant exactly
      // (EventMembershipUITests.testJoinEventRowReenablesAfterLeavingEvent):
      // every row here, including the current one, is only tappable while
      // nothing is joined. Rejoining is "leave, then tap a past row," never
      // an implicit leave-then-join on tap.
      .disabled(sensingCoordinator.joinedEventCode != nil)
    }
  }
}

#Preview {
  let proofStore = ProofStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("preview-past-events-\(UUID().uuidString).json"))
  proofStore.add(Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 3, eventCode: "ETHTOKYO2026"))
  proofStore.add(Proof(eventName: "Devcon SEA", date: Date().addingTimeInterval(-86_400 * 30), peersVerified: 1, eventCode: "DEVCON-SEA"))
  return NavigationStack {
    PastEventsView(sensingCoordinator: SensingCoordinator(), proofStore: proofStore, onRejoin: { _ in })
  }
}

#Preview("Empty") {
  let proofStore = ProofStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("preview-past-events-empty-\(UUID().uuidString).json"))
  return NavigationStack {
    PastEventsView(sensingCoordinator: SensingCoordinator(), proofStore: proofStore, onRejoin: { _ in })
  }
}

#Preview("Dark") {
  let proofStore = ProofStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("preview-past-events-dark-\(UUID().uuidString).json"))
  proofStore.add(Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 3, eventCode: "ETHTOKYO2026"))
  return NavigationStack {
    PastEventsView(sensingCoordinator: SensingCoordinator(), proofStore: proofStore, onRejoin: { _ in })
  }
  .preferredColorScheme(.dark)
}
