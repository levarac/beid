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
      BeidAdaptiveContent {
        VStack(alignment: .leading, spacing: BeidDesign.Spacing.section) {
          BeidPanel {
            VStack(alignment: .leading, spacing: BeidDesign.Spacing.content) {
              HStack(alignment: .top) {
                BeidGlyph(systemImage: "seal.fill", tint: DS.Color.proofSeal, size: 72)
                Spacer()
                Label("Verified", systemImage: "checkmark.circle.fill")
                  .font(DS.Font.cardTitle)
                  .foregroundStyle(DS.Color.proofSeal)
              }

              Text(proof.eventName)
                .font(DS.Font.sectionTitle)
                .fixedSize(horizontal: false, vertical: true)

              Text(Self.dateFormatter.string(from: proof.date))
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.textSecondary)
            }
          }

          BeidPanel {
            VStack(alignment: .leading, spacing: DS.Space.m) {
              Text("Proof")
                .font(DS.Font.cardTitle)
              BeidMetricRow(label: "Method", verbatimValue: proof.method)
              BeidMetricRow(label: "Peers verified", verbatimValue: "\(proof.peersVerified)")
              BeidMetricRow(label: "Status", value: "Verified", valueStyle: AnyShapeStyle(DS.Color.proofSeal))
            }
          }
        }
        .padding(BeidDesign.Spacing.screenHorizontal)
      }
    }
    .background(DS.Color.surfaceCanvas)
    .navigationTitle("Proof Detail")
    .navigationBarTitleDisplayMode(.inline)
  }
}

#Preview {
  NavigationStack {
    ItemDetailView(proof: Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 3))
  }
}
