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
      VStack(alignment: .leading, spacing: 20) {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(
            LinearGradient(
              colors: [Color.blue.opacity(0.7), Color.purple.opacity(0.6)],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
          .frame(height: 160)

        Text(proof.eventName)
          .font(.title.bold())

        Text(Self.dateFormatter.string(from: proof.date))
          .font(.subheadline)
          .foregroundStyle(.secondary)

        Divider()

        VStack(alignment: .leading, spacing: 12) {
          detailRow(label: "Method", value: proof.method)
          detailRow(label: "Peers verified", value: "\(proof.peersVerified)")
          detailRow(label: "Status", value: "Verified", valueColor: .green)
        }
      }
      .padding()
    }
    .navigationTitle("Proof Detail")
    .navigationBarTitleDisplayMode(.inline)
  }

  private func detailRow(label: String, value: String, valueColor: Color = .primary) -> some View {
    HStack {
      Text(label)
        .foregroundStyle(.secondary)
      Spacer()
      Text(value)
        .foregroundStyle(valueColor)
        .fontWeight(.semibold)
    }
  }
}

#Preview {
  NavigationStack {
    ItemDetailView(proof: Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 3))
  }
}
