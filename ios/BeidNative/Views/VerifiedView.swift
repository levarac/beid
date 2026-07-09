// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Screen 06c: Verified.
struct VerifiedView: View {
  let event: DemoEvent
  let peersVerified: Int

  var body: some View {
    VStack(spacing: 24) {
      Spacer()

      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 64))
        .foregroundStyle(.green)

      Text("Verified")
        .font(.title.bold())

      Text(event.name)
        .font(.title3)
        .foregroundStyle(.secondary)

      Text("\(peersVerified) peers verified")
        .font(.subheadline)
        .foregroundStyle(.secondary)

      Spacer()
      Spacer()
    }
  }
}

#Preview {
  VerifiedView(event: .sample, peersVerified: 3)
}
