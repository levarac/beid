// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import SwiftUI

/// Centers a screen's content at a readable width in regular horizontal size
/// classes while preserving the existing edge-to-edge compact-width layout.
struct BeidAdaptiveContent<Content: View>: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  private let regularMaxWidth: CGFloat
  private let content: Content

  init(
    regularMaxWidth: CGFloat = DS.Layout.stateContentMaxWidth,
    @ViewBuilder content: () -> Content
  ) {
    self.regularMaxWidth = regularMaxWidth
    self.content = content()
  }

  var body: some View {
    content
      .frame(maxWidth: horizontalSizeClass == .regular ? regularMaxWidth : .infinity)
      .frame(maxWidth: .infinity, alignment: .center)
  }
}
