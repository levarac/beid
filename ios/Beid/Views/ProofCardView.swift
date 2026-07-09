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
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top) {
        BeidGlyph(systemImage: "seal.fill", tint: .accentColor, size: 52)
        Spacer()
        Image(systemName: "checkmark.circle.fill")
          .font(.title3)
          .foregroundStyle(.green)
          .symbolRenderingMode(.hierarchical)
      }

      VStack(alignment: .leading, spacing: 6) {
        Text(proof.eventName)
          .font(.headline)
          .lineLimit(2)
          .minimumScaleFactor(0.86)

        Text(Self.dateFormatter.string(from: proof.date))
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      Divider()

      BeidMetricRow(label: "Peers", value: "\(proof.peersVerified)")
    }
    .padding(16)
    .frame(maxWidth: .infinity, minHeight: 188, alignment: .topLeading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: BeidDesign.Radius.card, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: BeidDesign.Radius.card, style: .continuous)
        .strokeBorder(.separator.opacity(0.32), lineWidth: 1)
    }
    .beidGlass(interactive: true, cornerRadius: BeidDesign.Radius.card)
  }
}

#Preview {
  ProofCardView(proof: Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 3))
    .frame(width: 160)
    .padding()
}
