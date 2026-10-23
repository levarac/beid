// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import SwiftUI

struct ProofCardView: View {
  let proof: Proof
  /// Overrides `proof.gradientSeed` for the artwork gradient only — title
  /// and date always come from `proof`. `nil` (the default) falls back to
  /// `proof.gradientSeed`, so every existing call site renders unchanged.
  /// `CollectionHomeView` passes the group's *oldest* session's seed here
  /// so a card's artwork never changes across re-scans, even though
  /// `proof` itself (driving title/date) is the group's newest session —
  /// see `docs/specs/collection-event-aggregation.md` §5.1.
  var artworkSeed: Int? = nil
  /// Distinct recorded sessions sharing this card's event. `1` (the
  /// default) renders exactly as before — no caption, no accessibility
  /// suffix.
  var sessionCount: Int = 1

  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    return formatter
  }()

  var body: some View {
    VStack(spacing: DS.Space.s) {
      Circle()
        .fill(DS.Artwork.proofCardGradient(seed: artworkSeed ?? proof.gradientSeed))
        .frame(width: DS.Size.proofCardArtwork, height: DS.Size.proofCardArtwork)
        .accessibilityHidden(true)

      Text(proof.eventName)
        .font(DS.Font.cardTitle)
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .minimumScaleFactor(0.86)

      Text(Self.dateFormatter.string(from: proof.date))
        .font(DS.Font.meta)
        .foregroundStyle(DS.Color.textSecondary)

      if sessionCount > 1 {
        Text(sessionCountText)
          .font(DS.Font.meta)
          .foregroundStyle(DS.Color.textSecondary)
      }
    }
    .padding(DS.Space.m)
    .frame(maxWidth: .infinity, alignment: .top)
    .beidSurface(cornerRadius: DS.Radius.card)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabelText)
  }

  /// Caption on a Collection Home card for an event recorded more than
  /// once — also reused (composed after a comma) inside
  /// `accessibilityLabelText` below for the same fact, per AGENTS.md's
  /// reuse rule (one meaning, one key).
  private var sessionCountText: String {
    String(
      localized: "proofCard.sessionCount",
      defaultValue: "^[\(sessionCount) sessions](inflect: true)",
      comment: "Caption on a Collection Home card for an event recorded more than once (the user re-scanned the same event in a separate app session). Count of distinct recorded sessions for this event, not devices or peers. Also reused, composed after a comma, inside proofCard.accessibilityLabel's VoiceOver text for the same fact when sessionCount > 1."
    )
  }

  private var accessibilityLabelText: String {
    let base = String(
      localized: "proofCard.accessibilityLabel",
      defaultValue: "Proof of \(proof.eventName), \(Self.dateFormatter.string(from: proof.date))",
      comment: "VoiceOver label for one proof card in the Collection Home grid — composed from the event name and collection date. When the event was recorded in more than one session, proofCard.sessionCount's own text (e.g. \"3 sessions\") is appended after a comma, so VoiceOver users get the same session-count fact sighted users see in the card's secondary caption."
    )
    guard sessionCount > 1 else { return base }
    return "\(base), \(sessionCountText)"
  }
}

#Preview {
  ProofCardView(proof: Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 3))
    .frame(width: 160)
    .padding()
}

#Preview("Multiple sessions") {
  ProofCardView(
    proof: Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 3),
    sessionCount: 3
  )
  .frame(width: 160)
  .padding()
}
