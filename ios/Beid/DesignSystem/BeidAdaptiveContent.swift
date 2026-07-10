// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Width limits for layouts that otherwise become hard to read on iPad.
/// These values belong to the design system because every screen uses the
/// same compact-versus-regular-width behavior.
enum BeidAdaptiveLayout {
  static let stateContentMaxWidth: CGFloat = 600
  static let collectionContentMaxWidth: CGFloat = 960
  static let regularGridCardMinimumWidth: CGFloat = 260
  static let compactGridCardMinimumWidth: CGFloat = 150
}

/// Centers a screen's content at a readable width in regular horizontal size
/// classes while preserving the existing edge-to-edge compact-width layout.
struct BeidAdaptiveContent<Content: View>: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  private let regularMaxWidth: CGFloat
  private let content: Content

  init(
    regularMaxWidth: CGFloat = BeidAdaptiveLayout.stateContentMaxWidth,
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
