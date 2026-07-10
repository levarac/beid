// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Screen 08: Item Detail — method, peers verified, status.
struct ItemDetailView: View {
  let proof: Proof

  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .long
    formatter.timeStyle = .short
    return formatter
  }()

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: BeidDesign.Spacing.section) {
        BeidPanel {
          VStack(alignment: .leading, spacing: BeidDesign.Spacing.content) {
            HStack(alignment: .top) {
              BeidGlyph(systemImage: "seal.fill", tint: .accentColor, size: 72)
              Spacer()
              Label("Verified", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
            }

            Text(proof.eventName)
              .font(.title.weight(.semibold))
              .fixedSize(horizontal: false, vertical: true)

            Text(Self.dateFormatter.string(from: proof.date))
              .font(.body)
              .foregroundStyle(.secondary)
          }
        }

        BeidPanel {
          VStack(alignment: .leading, spacing: 14) {
            Text("Proof")
              .font(.headline)
            BeidMetricRow(label: "Method", value: proof.method)
            BeidMetricRow(label: "Peers verified", value: "\(proof.peersVerified)")
            BeidMetricRow(label: "Status", value: "Verified", valueStyle: AnyShapeStyle(.green))
          }
        }
      }
      .padding(BeidDesign.Spacing.screenHorizontal)
    }
    .background(Color(.systemGroupedBackground))
    .navigationTitle("Proof Detail")
    .navigationBarTitleDisplayMode(.inline)
  }
}

#Preview {
  NavigationStack {
    ItemDetailView(proof: Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 3))
  }
}
