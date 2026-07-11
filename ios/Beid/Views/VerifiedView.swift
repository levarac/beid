// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Screen 06c: Verified.
struct VerifiedView: View {
  let event: DemoEvent
  let peersVerified: Int

  var body: some View {
    BeidStatusLayout(
      systemImage: "checkmark.circle.fill",
      assetImage: "proof-seal-mark",
      title: "Verified",
      message: "Your attendance proof is ready to be added to your collection.",
      accessory: {
      BeidPanel {
        VStack(alignment: .leading, spacing: BeidDesign.Spacing.content) {
          Text(event.name)
            .font(DS.Font.cardTitle)
            .fixedSize(horizontal: false, vertical: true)
          BeidMetricRow(label: "Peers verified", verbatimValue: "\(peersVerified)")
          BeidMetricRow(label: "Status", value: "Verified", valueStyle: AnyShapeStyle(.green))
        }
      }
      }
    )
  }
}

#Preview {
  VerifiedView(event: .sample, peersVerified: 3)
}
