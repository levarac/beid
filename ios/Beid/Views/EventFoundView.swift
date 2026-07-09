// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Screen 06a: Event Found — event card slides in.
struct EventFoundView: View {
  let event: DemoEvent

  @State private var appeared = false

  var body: some View {
    VStack(spacing: 24) {
      Spacer()

      Image(systemName: "sparkles")
        .font(.system(size: 40))
        .foregroundStyle(.blue)

      Text("Event Found")
        .font(.title3.weight(.semibold))
        .foregroundStyle(.secondary)

      VStack(spacing: 8) {
        Text(event.name)
          .font(.title.bold())
          .multilineTextAlignment(.center)
      }
      .padding(24)
      .frame(maxWidth: .infinity)
      .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.blue.opacity(0.12)))
      .padding(.horizontal, 32)
      .offset(y: appeared ? 0 : 40)
      .opacity(appeared ? 1 : 0)

      Spacer()
      Spacer()
    }
    .onAppear {
      withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
        appeared = true
      }
    }
  }
}

#Preview {
  EventFoundView(event: .sample)
}
