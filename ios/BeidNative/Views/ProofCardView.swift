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

  private var gradient: LinearGradient {
    let hue = Double(abs(proof.gradientSeed) % 360) / 360.0
    return LinearGradient(
      colors: [
        Color(hue: hue, saturation: 0.6, brightness: 0.9),
        Color(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.75),
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(gradient)
        .frame(height: 96)

      VStack(alignment: .leading, spacing: 4) {
        Text(proof.eventName)
          .font(.subheadline.weight(.semibold))
          .lineLimit(1)
        Text(Self.dateFormatter.string(from: proof.date))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.top, 8)
    }
  }
}

#Preview {
  ProofCardView(proof: Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 3))
    .frame(width: 160)
    .padding()
}
