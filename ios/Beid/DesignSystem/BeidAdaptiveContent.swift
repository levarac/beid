// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import SwiftUI

/// Constrains content to a readable width in regular horizontal size classes.
/// Content is centered by default; callers may choose another alignment.
struct BeidAdaptiveContent<Content: View>: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  private let regularMaxWidth: CGFloat
  private let alignment: Alignment
  private let content: Content

  init(
    regularMaxWidth: CGFloat = DS.Layout.stateContentMaxWidth,
    alignment: Alignment = .center,
    @ViewBuilder content: () -> Content
  ) {
    self.regularMaxWidth = regularMaxWidth
    self.alignment = alignment
    self.content = content()
  }

  var body: some View {
    content
      .frame(maxWidth: horizontalSizeClass == .regular ? regularMaxWidth : .infinity)
      .frame(maxWidth: .infinity, alignment: alignment)
  }
}

/// Uses leading alignment and size-class-aware horizontal padding for
/// large-title scroll screens, with a readable maximum width on iPad.
/// Inline-title screens can use their own content alignment instead.
struct BeidLargeTitleContent<Content: View>: View {
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
    BeidAdaptiveContent(regularMaxWidth: regularMaxWidth, alignment: .leading) {
      content
    }
    .padding(.horizontal, horizontalSizeClass == .regular ? DS.Space.m + DS.Space.xs : DS.Space.m)
  }
}
