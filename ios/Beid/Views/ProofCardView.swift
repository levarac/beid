// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

struct ProofCardView: View {
  let proof: Proof

  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    return formatter
  }()

  var body: some View {
    VStack(spacing: DS.Space.s) {
      Circle()
        .fill(DS.Artwork.proofCardGradient(seed: proof.gradientSeed))
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
    }
    .padding(DS.Space.m)
    .frame(maxWidth: .infinity, alignment: .top)
    .beidSurface(interactive: true, cornerRadius: BeidDesign.Radius.card)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabelText)
  }

  private var accessibilityLabelText: String {
    String(
      localized: "proofCard.accessibilityLabel",
      defaultValue: "Proof of \(proof.eventName), \(Self.dateFormatter.string(from: proof.date))",
      comment: "VoiceOver label for one proof card in the Collection Home grid — composed from the event name and collection date."
    )
  }
}

#Preview {
  ProofCardView(proof: Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 3))
    .frame(width: 160)
    .padding()
}

#Preview("Dark") {
  ProofCardView(proof: Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 3))
    .frame(width: 160)
    .padding()
    .preferredColorScheme(.dark)
}
